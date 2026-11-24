#!/usr/bin/env bash
# Kernel source patching: SUSFS, path_umount backport, hide_stuff, manual hooks.
#
# Everything here is idempotent and version-aware. Each step is skipped with a
# clear message when it is unnecessary (feature already present) rather than
# failing, because these trees are frequently already partially patched.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
# Resolved from this file's location, not $PWD -- several helpers below run
# with the working directory changed into the kernel tree.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ====================================================================== SUSFS

# susfs_branch_for KVER -- map a kernel version onto a susfs4ksu branch.
#
# susfs4ksu is branched per kernel version. The GKI branches are named after
# the Android release they ship with; where a kernel version spans two Android
# releases (5.10 -> android12/android13, 5.15 -> android13/android14) we pick
# the older, which is the one the vast majority of trees are based on.
# Override with SUSFS_BRANCH when that guess is wrong.
susfs_branch_for() {
	case "$1" in
		4.9)  echo "kernel-4.9" ;;
		4.14) echo "kernel-4.14" ;;
		4.19) echo "kernel-4.19" ;;
		5.4)  echo "kernel-5.4" ;;
		5.10) echo "gki-android12-5.10" ;;
		5.15) echo "gki-android13-5.15" ;;
		6.1)  echo "gki-android14-6.1" ;;
		6.6)  echo "gki-android15-6.6" ;;
		6.12) echo "gki-android16-6.12" ;;
		*)    echo "" ;;
	esac
}

susfs_apply() {
	local repo=${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}
	local branch=${SUSFS_BRANCH:-auto}
	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version from ${KERNEL_DIR}/Makefile"

	group "Applying SUSFS"

	if [ "$branch" = "auto" ]; then
		branch=$(susfs_branch_for "$kver")
		[ -n "$branch" ] || die "no susfs4ksu branch is known for kernel ${kver}; set SUSFS_BRANCH explicitly.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"
		info "kernel ${kver} -> susfs branch '${branch}'"
	fi

	ref_exists "$repo" "$branch" \
		|| die "susfs4ksu has no branch '${branch}'.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"

	local susfs_dir="${WORKSPACE}/susfs4ksu"
	rm -rf "$susfs_dir"
	retry 3 git clone -q --depth=1 -b "$branch" "$repo" "$susfs_dir" \
		|| die "failed to clone ${repo} @ ${branch}"

	local kp="${susfs_dir}/kernel_patches"
	[ -d "$kp" ] || die "unexpected susfs4ksu layout: ${kp} missing"

	# 1. Drop in the SUSFS sources. The non-GKI branches carry sus_su.c too.
	info "copying SUSFS sources into the kernel tree"
	cp -v "${kp}/fs/"*.c              "${KERNEL_DIR}/fs/"            2>/dev/null || true
	cp -v "${kp}/include/linux/"*.h   "${KERNEL_DIR}/include/linux/" 2>/dev/null || true

	# 2. Patch the kernel itself.
	local kernel_patch="${kp}/50_add_susfs_in_${branch}.patch"
	[ -f "$kernel_patch" ] || {
		# Fall back to whatever 50_* patch the branch actually ships.
		kernel_patch=$(find "$kp" -maxdepth 1 -name '50_add_susfs_in_*.patch' | head -n1)
	}
	[ -n "$kernel_patch" ] && [ -f "$kernel_patch" ] \
		|| die "no 50_add_susfs_in_*.patch found in ${kp}"

	( cd "$KERNEL_DIR" && apply_patch "$kernel_patch" 1 ) \
		|| die "the SUSFS kernel patch did not apply cleanly.
       This usually means SUSFS_BRANCH does not match your kernel. Detected
       kernel ${kver}, used branch '${branch}'."

	# 3. Patch the KernelSU side -- but only when the variant does not already
	#    ship SUSFS support. SukiSU-Ultra's 'builtin' branch, for instance,
	#    declares CONFIG_KSU_SUSFS itself; applying the patch on top conflicts.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	local ksu_patch="${kp}/KernelSU/10_enable_susfs_for_ksu.patch"

	if susfs_is_bundled; then
		info "${KSU_NAME:-the selected variant} already bundles SUSFS at ref '${KSU_REF_RESOLVED:-}'; skipping 10_enable_susfs_for_ksu.patch"
	elif [ ! -d "$ksu_dir" ]; then
		warn "KernelSU directory ${ksu_dir} not found; skipping the KernelSU-side SUSFS patch"
	elif [ ! -f "$ksu_patch" ]; then
		warn "branch ${branch} ships no KernelSU/10_enable_susfs_for_ksu.patch; skipping"
	else
		( cd "$ksu_dir" && apply_patch "$ksu_patch" 1 ) || {
			warn "the KernelSU-side SUSFS patch did not apply."
			warn "susfs4ksu's non-GKI branches were last updated in early 2025 and still"
			warn "target the old flat KernelSU layout; modern forks have since moved to a"
			warn "modular kernel/ tree. Try a variant/ref whose layout matches, or a fork"
			warn "that bundles SUSFS itself (e.g. KSU_VARIANT=sukisu-ultra KSU_REF=builtin)."
			die "SUSFS integration failed"
		}
	fi

	# Record the SUSFS version for the build summary.
	local sv
	sv=$(sed -nE 's/.*SUSFS_VERSION[[:space:]]+"([^"]+)".*/\1/p' \
		"${KERNEL_DIR}/include/linux/susfs.h" 2>/dev/null | head -n1)
	export_env SUSFS_VERSION "${sv:-unknown}"
	export_env SUSFS_BRANCH_RESOLVED "$branch"
	ok "SUSFS ${sv:-?} applied from branch ${branch}"
	summary "| SUSFS | \`${sv:-unknown}\` (branch \`${branch}\`) |"
	endgroup
}

# Does the selected variant+ref already contain SUSFS?
susfs_is_bundled() {
	local bundled=${KSU_SUSFS_BUNDLED_REFS:--} ref=${KSU_REF_RESOLVED:-}
	[ "$bundled" = "-" ] && return 1
	local r
	for r in $bundled; do
		[ "$r" = "$ref" ] && return 0
	done
	# Fall back to inspecting the tree, which is authoritative.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	[ -d "$ksu_dir" ] && grep -rqs 'CONFIG_KSU_SUSFS\|config KSU_SUSFS' "${ksu_dir}/kernel/Kconfig" 2>/dev/null
}

susfs_defconfig() {
	local defconfig=$1
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"

	# The SUSFS option set is NOT stable across branches, so it is discovered
	# from the Kconfig that was actually patched in rather than hardcoded.
	#
	# Concretely: the GKI branches ship SUSFS v2.x, which declares SUS_MAP and
	# has dropped the AUTO_ADD_*/SUS_OVERLAYFS/HAS_MAGIC_MOUNT knobs. The
	# non-GKI branches are still on v1.5.5 (last touched early 2025), which is
	# the exact opposite: it has the AUTO_ADD_* family and no SUS_MAP. A
	# hardcoded list is therefore wrong on one side or the other -- and wrong
	# in the silent direction, since an unknown symbol in a defconfig is simply
	# dropped, leaving the feature off with no warning.
	local syms
	syms=$(grep -rhoE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*' \
			"$ksu_dir" "${KERNEL_DIR}/fs/Kconfig" "${KERNEL_DIR}/drivers/kernelsu" 2>/dev/null \
		| awk '{print $2}' | sort -u)

	if [ -z "$syms" ]; then
		die "found no KSU_SUSFS Kconfig symbols to enable.
       The SUSFS sources are in the tree but nothing declares its options, so
       the feature would silently compile out and you would ship a kernel that
       looks patched but hides nothing. Check that the KernelSU-side patch
       applied, or pick a variant that bundles SUSFS."
	fi

	local s enabled=0
	for s in $syms; do
		case "$s" in
			# sus_su is the legacy in-kernel su backend, superseded by the
			# manager; overlayfs hiding conflicts with magic mount. Both are
			# off in the reference builds.
			KSU_SUSFS_SUS_SU | KSU_SUSFS_SUS_OVERLAYFS)
				kconf_disable "$defconfig" "CONFIG_${s}" ;;
			*)
				kconf_enable "$defconfig" "CONFIG_${s}"; enabled=$((enabled + 1)) ;;
		esac
	done
	ok "enabled ${enabled} SUSFS options discovered from Kconfig"
	debug "SUSFS symbols: $(printf '%s ' $syms)"
}

# =============================================================== path_umount

# path_umount() landed upstream in Linux 5.9. KernelSU uses it to unmount its
# own overlays before handing control to an app that is checking for root, so
# on older trees it has to be backported or module unmounting silently no-ops.
#
# The body below is upstream's, unchanged. It is inserted immediately before
# the comment that introduces the umount syscall, which puts it after
# do_umount() -- its only forward dependency -- in every tree from 4.9 to 5.4.
path_umount_apply() {
	local ns="${KERNEL_DIR}/fs/namespace.c"
	group "Backporting path_umount()"

	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version"

	if ver_ge "$kver" "5.9"; then
		info "kernel ${kver} already provides path_umount() upstream; nothing to do"
		endgroup; return 0
	fi
	[ -f "$ns" ] || die "fs/namespace.c not found"

	if grep -q '^int path_umount\|^static int path_umount' "$ns"; then
		info "path_umount() is already present in fs/namespace.c; nothing to do"
		endgroup; return 0
	fi

	local anchor='Now umount can handle mount points as well as block devices'
	grep -q "$anchor" "$ns" \
		|| die "could not find the insertion point in fs/namespace.c; patch this kernel manually"

	local snippet
	snippet=$(mktemp)
	# 'can_umount' is a separate helper upstream; guard it in case a partial
	# backport already added it.
	if ! grep -q 'static int can_umount' "$ns"; then
		cat >>"$snippet" <<'EOF'
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);

	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED) /* Check optimistically */
		return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;
	return 0;
}

EOF
	fi
	cat >>"$snippet" <<'EOF'
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;

	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);

	/* we mustn't call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}

EOF

	# Insert before the line *above* the anchor comment body, i.e. at the '/*'
	# that opens it.
	local lineno
	lineno=$(grep -n "$anchor" "$ns" | head -n1 | cut -d: -f1)
	# Walk back to the opening '/*' of that comment block.
	local start=$lineno
	while [ "$start" -gt 1 ] && ! sed -n "${start}p" "$ns" | grep -q '/\*'; do
		start=$((start - 1))
	done

	local tmp
	tmp=$(mktemp)
	head -n "$((start - 1))" "$ns" >"$tmp"
	cat "$snippet" >>"$tmp"
	tail -n "+${start}" "$ns" >>"$tmp"
	mv "$tmp" "$ns"
	rm -f "$snippet"

	grep -q '^int path_umount' "$ns" || die "path_umount() insertion failed"
	ok "path_umount() backported into fs/namespace.c (kernel ${kver})"
	summary "| path_umount | backported (kernel ${kver}) |"
	endgroup
}

# ============================================================== extra patches

SUKISU_PATCH_REPO=${SUKISU_PATCH_REPO:-https://github.com/ShirkNeko/SukiSU_patch.git}

# Clone the shared patch/tool repo once, on demand.
sukisu_patch_dir() {
	local dir="${WORKSPACE}/SukiSU_patch"
	if [ ! -d "$dir" ]; then
		retry 3 git clone -q --depth=1 "$SUKISU_PATCH_REPO" "$dir" \
			|| die "failed to clone ${SUKISU_PATCH_REPO}"
	fi
	printf '%s' "$dir"
}

# hide_stuff removes the most obvious KernelSU fingerprints from the build.
hide_stuff_apply() {
	group "Applying hide_stuff"
	local dir patch
	dir=$(sukisu_patch_dir)
	patch="${dir}/69_hide_stuff.patch"
	[ -f "$patch" ] || { warn "69_hide_stuff.patch not found in the patch repo; skipping"; endgroup; return 0; }
	( cd "$KERNEL_DIR" && apply_patch "$patch" 1 ) || warn "hide_stuff did not apply cleanly; continuing"
	endgroup
}

# Manual/syscall hook patches for pre-GKI trees, used when the fork expects the
# hooks to already exist in the kernel source rather than hooking via kprobes.
hooks_patch_apply() {
	local variant=${KSU_VARIANT:-none} kver
	kver=$(kernel_version "$KERNEL_DIR") || return 0

	group "Applying manual syscall hooks (kernel ${kver})"

	# ReSukiSU publishes scope-minimised hook patches keyed by kernel version.
	if [ "$variant" = "resukisu" ]; then
		local dir="${WORKSPACE}/ReSukiSU_Patches"
		[ -d "$dir" ] || retry 3 git clone -q --depth=1 \
			https://github.com/ReSukiSU/ReSukiSU_Patches.git "$dir" || true
		local p="${dir}/scope-minimized/kernel-${kver}.patch"
		if [ -f "$p" ]; then
			( cd "$KERNEL_DIR" && apply_patch "$p" 1 ) && { endgroup; return 0; }
		else
			info "ReSukiSU ships no scope-minimized patch for kernel ${kver}"
		fi
	fi

	# SukiSU's patch repo carries per-version hook patches too.
	if [ "$variant" = "sukisu-ultra" ]; then
		local dir p
		dir=$(sukisu_patch_dir)
		for p in "${dir}/${kver}/"*hook*.patch "${dir}/hooks/syscall_hooks.patch"; do
			[ -f "$p" ] || continue
			if ( cd "$KERNEL_DIR" && apply_patch "$p" 1 ); then endgroup; return 0; fi
		done
	fi

	# Fall back to the in-repo sed script, which is what this action shipped
	# historically and still works for the 4.9-5.4 KernelSU 0.9.x hook API.
	info "falling back to the bundled legacy hook script"
	( cd "$KERNEL_DIR" && bash "${REPO_ROOT}/patches/legacy_ksu_hooks.sh" )
	endgroup
}

# ======================================================================== KPM

# SukiSU-Ultra's Kernel Patch Module support needs a post-link step: the
# patch_linux tool rewrites the built Image and emits oImage.
kpm_patch_image() {
	local image=$1
	group "Applying KPM (patch_linux)"
	local dir tool
	dir=$(sukisu_patch_dir)
	tool="${dir}/kpm/patch_linux"
	[ -f "$tool" ] || die "kpm/patch_linux not found in ${SUKISU_PATCH_REPO}"
	chmod +x "$tool"
	( cd "$(dirname "$image")" && "$tool" "$(basename "$image")" ) \
		|| die "patch_linux failed"
	local out
	out="$(dirname "$image")/oImage"
	[ -f "$out" ] || die "patch_linux did not produce oImage"
	mv -f "$out" "$image"
	ok "KPM applied to $(basename "$image")"
	summary "| KPM | applied |"
	endgroup
}


# Locate the defconfig build.sh will hand to `make <name>_defconfig`.
detect_defconfig() {
	local name="${KERNEL_NAME:-}" cfgdir="${KERNEL_DIR}/arch/arm64/configs"
	if [ -z "${name}" ] && [ -f "${WORKSPACE}/config.env" ]; then
		name=$(sed -n "s/^KERNEL_NAME=[\"']*\([^\"']*\)[\"']*$/\1/p" "${WORKSPACE}/config.env" | head -n1)
	fi
	if [ -n "${name}" ] && [ -f "${cfgdir}/${name}_defconfig" ]; then
		echo "${cfgdir}/${name}_defconfig"
		return 0
	fi
	local best
	best=$(grep -l 'CONFIG_MTK_PLATFORM' "${cfgdir}"/oplus*_defconfig "${cfgdir}"/oppo*_defconfig 2>/dev/null | head -n1 || true)
	if [ -z "${best}" ]; then
		best=$(grep -l 'CONFIG_MTK_PLATFORM' "${cfgdir}"/*_defconfig 2>/dev/null | head -n1 || true)
	fi
	[ -n "${best}" ] && { echo "${best}"; return 0; }
	return 1
}

# ============================================ public tree Kconfig sanitizer

# OPPO's open-source drop references private OPLUS_*/vendor directories from
# Kconfig files, guarded by '#ifdef SOME_FEATURE' *comment* lines. Upstream
# kconfig has no such mechanism: it reads those lines as plain comments and then
# tries to load every `source` unconditionally, aborting the whole parse on the
# first missing file ("cannot open file ..."). This walks every Kconfig in the
# tree and comments out `source` lines whose target does not exist.
sanitize_public_tree() {
	group "Sanitizing dangling Kconfig sources"
	local py
	py=$(mktemp)
	cat >"$py" <<'PYEOF'
import os, re, sys

root = sys.argv[1]
kconf_pat = re.compile(r'^([ \t]*)source[ \t]+("[^"]+"|\S+)[ \t]*$')
obj_pat = re.compile(r'^([ \t]*)(?:obj|lib|build|subdir)-(?:(?:y|m)|\$[^\s=]+)?[ \t]*\+?=[ \t]*([^\s#]+(?:/|\.o|\.c))[ \t]*(?:#.*)?$')

touched = []

def obj_target_ok(base, target, composites=frozenset()):
    # A dangling symlink into vendor/oplus is as absent as a deleted dir.
    full = os.path.abspath(os.path.join(base, target))
    if target.endswith('/'):
        if not os.path.isdir(full):
            return False
        return any(os.path.isfile(os.path.join(full, n)) for n in ('Makefile', 'Kbuild'))
    # obj entries name the *object*; kbuild builds it from a source file that
    # sits next to it (or a few directories up).  A dangling .c symlink therefore
    # has to be treated as missing.
    name = target[:-2] if target.endswith('.o') else target
    if name in composites:
        # built from several objects, e.g. snd-soc-x-objs := a.o b.o
        return True
    stem = os.path.abspath(os.path.join(base, name))
    return any(os.path.exists(stem + ext) for ext in ('', '.c', '.S', '.s'))

for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ('.git', '.repo', '.cache')]
    for name in filenames:
        is_kconf = name == 'Kconfig' or name.startswith('Kconfig')
        is_make = name in ('Makefile', 'Kbuild')
        if not (is_kconf or is_make):
            continue
        path = os.path.join(dirpath, name)
        try:
            lines = open(path, encoding='utf-8', errors='surrogateescape').read().split('\n')
        except OSError:
            continue
        composites = set()
        if is_make:
            # Any "<name>-<suffix>[:+]?=" definition means "<name>.o" is built from
            # several objects -- including the "<name>-objs-y :=" and
            # "<name>-objs := $(<name>-objs-y)" / "<name>-y +=" spellings, which an
            # anchored (?:objs|y) regex misses (that silently commented
            # "obj-y += isofs.o" and broke fs/built-in.o).
            for line in lines:
                mc = re.match(r'^[ \t]*([A-Za-z0-9_.\-]+)-[A-Za-z0-9_.$()\-]*[ \t]*[:+]?=', line)
                if mc:
                    composites.add(mc.group(1))
        # A Makefile that generates .c files from another format (logos from
        # .pbm/.ppm, tables from scripts) never has the .o on disk before the
        # build, so treating "no such file" as "stripped" wrongly drops them.
        gen_c = bool(re.search(r'^[^\s:#][^:]*%\.c[^:]*:', '\n'.join(lines), re.M))
        out, changed = [], 0
        for line in lines:
            hit = None
            if is_kconf:
                m = kconf_pat.match(line)
                if m:
                    target = m.group(2).strip('"')
                    if '$' not in target and not os.path.exists(os.path.join(root, target)):
                        hit = target
            elif is_make:
                m = obj_pat.match(line)
                if m:
                    target = m.group(2)
                    if '$' not in target and not gen_c \
                       and not obj_target_ok(dirpath, target, composites):
                        hit = target
            if hit is not None:
                indent = line[:len(line) - len(line.lstrip())]
                out.append('%s# %s' % (indent, line[len(indent):]))
                changed += 1
                touched.append('%s -> %s' % (os.path.relpath(path, root), hit))
                continue
            out.append(line)
        if changed:
            open(path, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(out))

for item in touched:
    print('  commented: %s' % item)
print('  total: %d dangling reference(s)' % len(touched))

PYEOF
	python3 "$py" "${KERNEL_DIR}" || warn "sanitizer failed; continuing with the tree as-is"
	rm -f "$py"
	endgroup
}


# ====================================== stripped vendor implementations neutralizer

# OPPO ships several features whose implementation directories are absent from
# the public drop (kernel/sched_assist, include/linux/sched_assist,
# mm/oppo_healthinfo, block/foreground_io_opt, drivers/soc/oplus/iomonitor,
# mm/malloc_track, mm/task_mem, drivers/soc/oplus/system, ...), while the core
# tree still #includes their headers and calls their helpers.  Those calls are
# normally invisible because the feature macros are undefined -- except that
# OplusKernelEnvConfig.mk force-defines every ALLOWED_MCROS entry for all
# translation units, which makes the dangling hooks live and kills the build at
# the first #include.  Same story for a few defconfig symbols whose code lives
# in the stripped dirs.
#
# So: comment those macros out of ALLOWED_MCROS, neutralize the PREFER_SILVER
# ifeq that exports its CONFIG from the make environment, and force the matching
# CONFIG symbols off in the defconfig.  Idempotent.
neutralize_stripped_hooks() {
	group "Neutralizing hooks whose implementation dirs are absent"
	local defconfig
	if ! defconfig=$(detect_defconfig); then
		warn "no defconfig found; skipping feature neutralization"
		endgroup
		return 0
	fi
	python3 - "${KERNEL_DIR}" "${defconfig}" <<'PYEOF'
import os, re, sys

root, defconf = sys.argv[1], sys.argv[2]

MACROS = [
    'OPLUS_FEATURE_SCHED_ASSIST',   # kernel/sched_assist + include/linux/sched_assist
    'OPLUS_FEATURE_FG_IO_OPT',      # block/foreground_io_opt
    'OPLUS_FEATURE_IOMONITOR',      # drivers/soc/oplus/iomonitor
    'OPLUS_FEATURE_HEALTHINFO',     # mm/oppo_healthinfo + include/soc/oplus/healthinfo.h
    'OPLUS_FEATURE_PHOENIX',        # drivers/soc/oplus/system/oplus_phoenix
    'OPLUS_FEATURE_MULTI_FREEAREA',  # mm/multi_freearea
    'OPLUS_FEATURE_PROCESS_RECLAIM', # mm/process_mm_reclaim
    'OPLUS_FEATURE_MEMLEAK_DETECT',  # memleak_detect/svelte
    'OPLUS_FEATURE_LOWMEM_DBG',      # oplus_performance/lowmem_dbg
    'OPLUS_FEATURE_MIDAS',           # power/midas
    'OPLUS_FEATURE_NANDSWAP',        # oplus_performance/oplus_nandswap
    'OPLUS_FEATURE_TASK_CPUSTATS',   # oplus_performance/task_cpustats
    'OPLUS_FEATURE_UIFIRST',         # oplus_performance/uifirst
    'OPLUS_FEATURE_AGINGTEST',       # oplus_performance aging tests
    'OPLUS_FEATURE_SVELTE',          # memleak_detect/svelte
]

DISABLE = [
    'OPLUS_FG_IO_OPT',
    'IOMONITOR',
    'OPLUS_JANK_INFO',
    'OPLUS_MEM_MONITOR',
    'KMALLOC_DEBUG',
    'VMALLOC_DEBUG',
    'DUMP_TASKS_MEM',
    'OPLUS_FEATURE_AUDIO_OPT',
    'FG_TASK_UID',
    'OPLUS_FEATURE_HUNG_TASK_ENHANCE',
    'NANDSWAP',
    'OPLUS_HEALTHINFO',
    'OPLUS_PREFER_SILVER',
    'DEBUG_INFO',                   # binutils 2.27 + clang 14 choke on .file/.loc
    'DYNAMIC_TUNNING_SWAPPINESS',   # 'two_hundred' came from a stripped header
    'IMQ',                          # sk_buff extensions missing from the drop
    'NETFILTER_XT_TARGET_IMQ',
    # Boot logos are generated from .pbm/.ppm by a pattern rule; the sanitizer
    # cannot see the .c and drops the objects, which then leaves logo.c calling
    # symbols nobody defines.  Android gets its splash from the bootloader, so
    # the in-kernel logo is dead weight either way.
    'LOGO',
    'LOGO_LINUX_MONO',
    'LOGO_LINUX_VGA16',
    'LOGO_LINUX_CLUT224',
    'LOGO_BLACKFIN_CLUT224',
    'LOGO_BLACKFIN_VGA16',
    'LOGO_DEC_CLUT224',
    'LOGO_MAC_CLUT224',
    'LOGO_PARISC_CLUT224',
    'LOGO_SGI_CLUT224',
    'LOGO_SUN_CLUT224',
    'LOGO_SUPERH_MONO',
    'LOGO_SUPERH_VGA16',
    'LOGO_SUPERH_CLUT224',
    'LOGO_M32R_CLUT224',
]

env_mk = os.path.join(root, 'OplusKernelEnvConfig.mk')
if os.path.isfile(env_mk):
    text = open(env_mk, encoding='utf-8', errors='surrogateescape').read()
    # NB: never comment entries of ALLOWED_MCROS -- every line of the list ends
    # in a backslash, and GNU make continues a comment ending in one, which
    # silently swallows all following entries (a real trap: it dropped
    # OPLUS_BUG_STABILITY and broke the panel structs).
    guard = 'ALLOWED_MCROS := $(filter-out ' + ' '.join(MACROS) + ',$(ALLOWED_MCROS))'
    anchor = '$(foreach myfeature,$(ALLOWED_MCROS),'
    if 'filter-out ' + MACROS[0] not in text and anchor in text:
        note = ('# Features whose implementations are absent from the public drop:\n'
                '# filter them out so the -D never reaches a translation unit.\n')
        text = text.replace(anchor, note + guard + '\n\n' + anchor, 1)
        open(env_mk, 'w', encoding='utf-8', errors='surrogateescape').write(text)
        print('  OplusKernelEnvConfig.mk: %d hook macro(s) filtered out' % len(MACROS))
    else:
        print('  OplusKernelEnvConfig.mk: hook macros already filtered')

lines = open(defconf, encoding='utf-8', errors='surrogateescape').read().split('\n')
keep, commented = [], 0
for line in lines:
    m = re.match(r'^[ \t]*CONFIG_([A-Za-z0-9_]+)[ \t]*=[ \t]*\S+[ \t]*$', line)
    if m and m.group(1) in DISABLE:
        keep.append('# ' + line.strip())
        commented += 1
        continue
    m2 = re.match(r'^[ \t]*#\s*CONFIG_([A-Za-z0-9_]+)\s+is not set[ \t]*$', line)
    if m2 and m2.group(1) in DISABLE:
        continue
    keep.append(line)

body = '\n'.join(keep).rstrip('\n')
tail = ['', '# --- implementations stripped from the public drop: keep these off ---']
tail += ['# CONFIG_%s is not set' % s for s in DISABLE]
open(defconf, 'w', encoding='utf-8', errors='surrogateescape').write(body + '\n' + '\n'.join(tail) + '\n')
print('  defconfig: %d active line(s) commented, %d symbol(s) forced off' % (commented, len(DISABLE)))
PYEOF
	endgroup
}

# Source-level leftovers that are not explained by a missing directory:
# an include path the drop forgot, call sites whose callees are CONFIG-gated,
# and stand-ins for helpers core files call unguarded.
repair_stripped_upstream() {
	group "Repairing source-level leftovers of the stripped drop"
	python3 - "${KERNEL_DIR}" <<'PYEOF'
import os, re, sys

root = sys.argv[1]

# kernel/sched/Makefile: private include dir the drop forgot
smk = os.path.join(root, 'kernel/sched/Makefile')
if os.path.isfile(smk):
    src = open(smk, encoding='utf-8', errors='surrogateescape').read()
    inc = 'ccflags-y += -I$(srctree)/drivers/misc/mediatek/base/power/mcdi/include'
    if inc not in src:
        open(smk, 'w', encoding='utf-8', errors='surrogateescape').write(inc + '\n' + src)
        print('  kernel/sched/Makefile: mcdi include dir added')

# mm/slub.c: callee is CONFIG_SLUB_DEBUG-only, call site is not
slub = os.path.join(root, 'mm/slub.c')
if os.path.isfile(slub):
    src = open(slub, encoding='utf-8', errors='surrogateescape').read()
    call = '\tsetup_page_debug(s, start, order);\n'
    if call in src and '#ifdef CONFIG_SLUB_DEBUG\n' + call not in src:
        src = src.replace(call, '#ifdef CONFIG_SLUB_DEBUG\n' + call + '#endif\n', 1)
        open(slub, 'w', encoding='utf-8', errors='surrogateescape').write(src)
        print('  mm/slub.c: setup_page_debug() call guarded')

# include/linux/sched.h: the drop leaves a duplicated #endif at EOF (the
# CONFIG_SCHED_TUNE block is closed twice), which every includer reports as
# "#endif without #if".  Drop the duplicate; the block then simply sits outside
# the include guard, exactly as the rest of the vendor additions do.
sh = os.path.join(root, 'include/linux/sched.h')
if os.path.isfile(sh):
    src = open(sh, encoding='utf-8', errors='surrogateescape').read()
    dup = '\t#endif\n#endif /* CONFIG_SCHED_TUNE */\n'
    tail = '#endif\n#endif /* CONFIG_SCHED_TUNE */\n'
    if tail in src:
        src = src.replace(tail, '#endif\n')
        open(sh, 'w', encoding='utf-8', errors='surrogateescape').write(src)
        print('  include/linux/sched.h: duplicated #endif dropped')

# kernel/sched/fair.c: two assist call sites sit under CONFIG_SCHED_WALT only,
# while every other call site in the tree is wrapped in OPLUS_FEATURE_SCHED_ASSIST.
fair = os.path.join(root, 'kernel/sched/fair.c')
if os.path.isfile(fair):
    src = open(fair, encoding='utf-8', errors='surrogateescape').read()
    old = """\tif (likely(!walt_disabled && (sysctl_sched_use_walt_task_util
\t\t|| (sysctl_sched_assist_enabled && test_task_ux(p)
\t\t&& is_sched_assist_scene()))))
"""
    new_site = """\tif (likely(!walt_disabled && (sysctl_sched_use_walt_task_util
#if defined(OPLUS_FEATURE_SCHED_ASSIST)
\t\t|| (sysctl_sched_assist_enabled && test_task_ux(p)
\t\t&& is_sched_assist_scene())
#endif
\t\t)))
"""
    if old in src:
        src = src.replace(old, new_site)
        open(fair, 'w', encoding='utf-8', errors='surrogateescape').write(src)
        print('  kernel/sched/fair.c: assist clause guarded at both call sites')

# kernel/sched/tune.c: boost threshold is declared only when the assist macro is
# on, but this block uses it under CONFIG_MTK_SCHED_BOOST alone.
tune = os.path.join(root, 'kernel/sched/tune.c')
if os.path.isfile(tune):
    src = open(tune, encoding='utf-8', errors='surrogateescape').read()
    old = """\t\tif (READ_ONCE(p->se.avg.util_avg) > sysctl_boost_task_threshold) {
\t\t\t*task_prefer = SCHED_PREFER_BIG;
\t\t}
"""
    new_site = """#if defined(OPLUS_FEATURE_SCHED_ASSIST) && defined(CONFIG_SCHED_WALT)
\t\tif (READ_ONCE(p->se.avg.util_avg) > sysctl_boost_task_threshold) {
\t\t\t*task_prefer = SCHED_PREFER_BIG;
\t\t}
#else
\t\t*task_prefer = SCHED_PREFER_BIG;
#endif
"""
    if old in src:
        src = src.replace(old, new_site, 1)
        open(tune, 'w', encoding='utf-8', errors='surrogateescape').write(src)
        print('  kernel/sched/tune.c: boost threshold guarded')

# include/linux/prefer_silver.h is a dangling symlink; the heuristics are gone.
ps = os.path.join(root, 'include/linux/prefer_silver.h')
if os.path.islink(ps) and not os.path.exists(ps):
    os.unlink(ps)
if not os.path.exists(ps):
    open(ps, 'w', encoding='utf-8').write("""/* SPDX-License-Identifier: GPL-2.0 */
/* Stand-in for the stripped prefer-silver heuristics: no preference, so the
 * callers fall back to the upstream placement path. */
#ifndef __OPLUS_PREFER_SILVER_STUB_H
#define __OPLUS_PREFER_SILVER_STUB_H
#include <linux/sched.h>
static inline int prefer_silver_check_ux(struct task_struct *p) { return 0; }
static inline int prefer_silver_check_freq(int cpu) { return 0; }
static inline int prefer_silver_check_task_util(struct task_struct *p) { return 0; }
static inline int prefer_silver_check_cpu_util(int cpu) { return 0; }
#endif
""")
    print('  include/linux/prefer_silver.h: stub installed')

# audio_dsp's sibling include dir is not on the path of sound/soc/mediatek/common
amk = os.path.join(root, 'sound/soc/mediatek/common/Makefile')
if os.path.isfile(amk):
    src = open(amk, encoding='utf-8').read()
    if 'audio_ipi/common/tasks/audplayback' not in src:
        open(amk, 'w', encoding='utf-8').write(
            'ccflags-y += -I$(srctree)/drivers/misc/mediatek/audio_ipi/common/tasks/audplayback\n' + src)
        print('  sound/soc/mediatek/common/Makefile: audio_ipi include added')

# PREFER_SILVER exports its CONFIG from the make environment; drop that branch.
env2 = os.path.join(root, 'OplusKernelEnvConfig.mk')
if os.path.isfile(env2):
    text = open(env2, encoding='utf-8', errors='surrogateescape').read()
    lines = text.split('\n')
    out, on, hit = [], False, 0
    for l in lines:
        if l.strip() == 'ifeq ($(OPLUS_FEATURE_PREFER_SILVER),yes)':
            on = True
        if on:
            out.append('# ' + l if l.strip() else l)
            hit += 1
            if l.strip() == 'endif':
                on = False
            continue
        out.append(l)
    if hit:
        open(env2, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(out))
        print('  OplusKernelEnvConfig.mk: PREFER_SILVER ifeq neutralized')

# mtk_nanohub.h uses uint*_t without pulling types.h (include order changed)
nh = os.path.join(root, 'drivers/misc/mediatek/sensor/2.0/mtk_nanohub/mtk_nanohub.h')
if os.path.isfile(nh):
    src = open(nh, encoding='utf-8', errors='surrogateescape').read()
    if '<linux/types.h>' not in src:
        src = src.replace('#include <linux/ioctl.h>',
                          '#include <linux/ioctl.h>\n#include <linux/types.h>', 1)
        open(nh, 'w', encoding='utf-8', errors='surrogateescape').write(src)
        print('  mtk_nanohub.h: types.h added')

# imgsensor spells the private header with two p characters
alt = os.path.join(root, 'include/soc/oplus/system/oppo_project.h')
if os.path.isdir(os.path.dirname(alt)) and not os.path.exists(alt):
    open(alt, 'w', encoding='utf-8').write(
        '/* SPDX-License-Identifier: GPL-2.0 */\n'
        '/* alias: imgsensor spells the private header with two p characters */\n'
        '#include <soc/oplus/system/oplus_project.h>\n')
    print('  oppo_project.h alias created')

# top Makefile: vendor leftovers trip -Werror-only diagnostics
mk = os.path.join(root, 'Makefile')
src = open(mk, encoding='utf-8', errors='surrogateescape').read()
marker2 = '# vendor code whose support was stripped: keep these non-fatal'
if marker2 not in src:
    add = ('\n' + marker2 + '\n'
           'KBUILD_CFLAGS += -Wno-unused-variable -Wno-unused-but-set-variable '
           '-Wno-strict-prototypes -Wno-macro-redefined -Wno-void-pointer-to-int-cast -Wno-fortify-source\n')
    open(mk, 'w', encoding='utf-8', errors='surrogateescape').write(src.rstrip('\n') + '\n' + add)
    print('  Makefile: warning suppressions appended')

# The OPPO charger header hardcodes the vendor tree layout
# ('../../../../kernel-4.14/...'), which only exists on their build server.
bat = os.path.join(root, 'drivers/power/oplus/charger_ic/oplus_battery_mtk6877R.h')
if os.path.isfile(bat):
    src = open(bat, encoding='utf-8', errors='surrogateescape').read()
    bad = '../../../../kernel-4.14/drivers/misc/mediatek/typec/tcpc/inc/tcpm.h'
    good = '../../../misc/mediatek/typec/tcpc/inc/tcpm.h'
    if bad in src:
        open(bat, 'w', encoding='utf-8', errors='surrogateescape').write(
            src.replace(bad, good))
        print('  oplus_battery_mtk6877R.h: tcpm.h path made tree-relative')

# NR_IONCACHE_PAGES sits behind OPLUS_FEATURE_HEALTHINFO in the enum, but ion
# and meminfo read it unguarded.  Keep the slot so the callers still resolve; it
# simply stays at zero now that the healthinfo counters are gone.
mz = os.path.join(root, 'include/linux/mmzone.h')
if os.path.isfile(mz):
    src = open(mz, encoding='utf-8', errors='surrogateescape').read()
    guard = ('#ifdef OPLUS_FEATURE_HEALTHINFO\n'
             '\tNR_IONCACHE_PAGES,\n'
             '#endif /* OPLUS_FEATURE_HEALTHINFO */\n')
    if guard in src:
        src = src.replace(guard, '\tNR_IONCACHE_PAGES,\n', 1)
        open(mz, 'w', encoding='utf-8', errors='surrogateescape').write(src)
        print('  mmzone.h: NR_IONCACHE_PAGES kept outside the feature guard')

# Thermal code compares get_eng_version() against HIGH_TEMP_AGING from the
# stripped project header; every one of those files already pulls
# mt-plat/mtk_thermal_monitor.h, so the stub rides in through that header.
tm = os.path.join(root, 'drivers/misc/mediatek/include/mt-plat/mtk_thermal_monitor.h')
if os.path.isfile(tm):
    src = open(tm, encoding='utf-8', errors='surrogateescape').read()
    marker = 'the stripped OPPO project ids'
    if marker not in src:
        block = ('\n/* added by patches.sh: ' + marker + ' are constant here */\n'
                 '#include <soc/oplus/system/oplus_project.h>\n'
                 '#ifndef HIGH_TEMP_AGING\n'
                 '#define HIGH_TEMP_AGING 1\n'
                 '#endif\n')
        open(tm, 'w', encoding='utf-8', errors='surrogateescape').write(src.rstrip('\n') + '\n' + block)
        print('  mtk_thermal_monitor.h: project ids stubbed in')
PYEOF
	endgroup
}

# The drop keeps symlinks into vendor/oplus but not the tree they point at, so
# a few always-compiled files still include headers from it.  Two of those are
# needed unconditionally: the project/boot-mode helper and the mm kevent reporter.
install_private_stubs() {
	local inc="${KERNEL_DIR}/include/soc/oplus/system"
	if [ -L "${inc}" ] && [ ! -e "${inc}" ]; then
		rm -f "${inc}"
	fi
	mkdir -p "${inc}"
	if [ ! -f "${inc}/oplus_project.h" ]; then
		cat >"${inc}/oplus_project.h" <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Stand-in for the OPPO project header: the public drop ships only a dangling
 * symlink into vendor/oplus/kernel/system, and the implementation behind it is
 * gone too.  The project/PCB/operator ids only select panel, touch and camera
 * firmware variants, so a constant 0 keeps every caller compiling and linking.
 * Callers that need oppo_boot_mode pull <mt-plat/mtk_boot_common.h> themselves.
 */
#ifndef __OPLUS_PROJECT_STUB_H
#define __OPLUS_PROJECT_STUB_H

#include <linux/types.h>

static inline unsigned int get_project(void)
{
	return 0;
}

/* Same signatures as the private header so a TU that also pulls the real
 * include/soc/oppo/oppo_project.h still agrees with it. */
static inline unsigned int is_project(int project)
{
	(void)project;
	return 0;
}

static inline unsigned int get_eng_version(void)
{
	return 0;
}

static inline unsigned int get_PCB_Version(void)
{
	return 0;
}

static inline int32_t get_Operator_Version(void)
{
	return 0;
}

/* Engineering-version ids the charging / thermal code compares against.
 * get_eng_version() is stubbed to 0 ("normal build"), so the ids must be
 * non-zero and distinct: eng-mode charging paths stay off while the
 * production over-temperature protection still works. */
#define AGING		1
#define FACTORY		2
#define HIGH_TEMP_AGING	3

#endif /* __OPLUS_PROJECT_STUB_H */
EOF
	fi
	if [ ! -f "${inc}/oplus_mm_kevent_fb.h" ]; then
		cat >"${inc}/oplus_mm_kevent_fb.h" <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/* Stand-in for the stripped mm kevent reporter: diagnostics only, no-ops. */
#ifndef __OPLUS_MM_KEVENT_FB_STUB_H
#define __OPLUS_MM_KEVENT_FB_STUB_H
#define MM_KEVENT_MAX_PAYLOAD_SIZE	512
#define MM_FB_KEY_RATELIMIT_1MIN	0
#define MM_FB_KEY_RATELIMIT_5MIN	1
#define MM_FB_KEY_RATELIMIT_1H	2
#define OPLUS_AUDIO_EVENTID_HEADSET_DET	0
#define OPLUS_AUDIO_EVENTID_AFE_ERROR	1
static inline int upload_mm_fb_kevent_to_atlas_limit(int id, const char *buf,
						     int limit)
{
	return 0;
}
static inline int mm_fb_audio_kevent_named(int id, int limit, const char *buf)
{
	return 0;
}
static inline int mm_fb_display_kevent(const char *fmt, ...)
{
	return 0;
}
#endif
EOF
	fi
	if [ ! -f "${inc}/kernel_fb.h" ]; then
		cat >"${inc}/kernel_fb.h" <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/* Stand-in for the stripped OPPO kernel feedback reporter: diagnostics only. */
#ifndef __OPLUS_KERNEL_FB_STUB_H
#define __OPLUS_KERNEL_FB_STUB_H
#define FB_SENSOR		0
#define FB_SENSOR_ID_CRASH	0
static inline int oplus_kevent_fb_str(int module, int id, const char *buf)
{
	return 0;
}
#endif
EOF
	fi
	ok "private header stubs installed in include/soc/oplus/system"
}

# clang is told to use GNU as (the tree hard-codes -no-integrated-as) and looks
# the assembler up as <target>-as on PATH.  The kernel toolchain only ships
# aarch64-linux-android-as, so clang silently falls back to the host x86 as and
# dies on "-EL".  Put the right alias on PATH for every later step.
# Three more things the vendor drop gets wrong once the private trees are gone.
#   * Makefiles sprinkled with a bare -Werror: our stubs necessarily produce a
#     few unused-variable / cast warnings that are not real problems.
#   * A handful of headers that hard-code "../../../../kernel-4.14/..." as if
#     the tree still had its build-time directory name.
#   * NR_IONCACHE_PAGES, a zone stat item that only exists under
#     OPLUS_FEATURE_HEALTHINFO (which we turn off), still referenced by 4
#     call sites of the *stripped* ion / meminfo code.
freshen_vendor_build() {
	group "Freshening vendor build assumptions"
	python3 - "$KERNEL_DIR" <<'PYEOF'
import os, re, sys

root = sys.argv[1]
werr = re.compile(r'-Werror(?![-=])')
changed, stripped, ion = [], [], []

for top in ('drivers', 'sound', 'block', 'fs'):
    base = os.path.join(root, top)
    if not os.path.isdir(base):
        continue
    for dirpath, dirnames, files in os.walk(base):
        dirnames[:] = [d for d in dirnames if d != 'out']
        for f in files:
            path = os.path.join(dirpath, f)
            if not f.endswith(('.c', '.h', '.mk')) and f != 'Makefile' \
               and not f.startswith('Makefile'):
                continue
            try:
                with open(path, encoding='utf-8', errors='surrogateescape') as fp:
                    src = fp.read()
            except OSError:
                continue

            new = src
            if 'kernel-4.14/' in new:
                new = new.replace('kernel-4.14/', '')
                stripped.append(path)
            if 'NR_IONCACHE_PAGES' in new:
                new = new.replace('global_zone_page_state(NR_IONCACHE_PAGES)',
                                  '0UL')
                ion.append(path)
            if f == 'Makefile' or f.startswith('Makefile') or f.endswith('.mk'):
                if werr.search(new):
                    new = werr.sub('-Wno-error', new)
                    changed.append(path)

            if new != src:
                with open(path, 'w', encoding='utf-8',
                          errors='surrogateescape') as fp:
                    fp.write(new)

print('  -Werror downgraded in %d Makefile(s)' % len(changed))
print('  hard-coded kernel-4.14/ prefix removed in %d file(s)' % len(stripped))
print('  NR_IONCACHE_PAGES references neutralised in %d file(s)' % len(ion))
PYEOF
	endgroup
}

link_arm_assembler() {
	local asdir="${WORKSPACE}/gcc-64/bin"
	local real="${asdir}/aarch64-linux-android-as"
	if [ ! -x "${real}" ]; then
		warn "aarch64 assembler not found at ${real}; skipping"
		return 0
	fi
	local shimdir="${HOME}/.as-shims"
	mkdir -p "${shimdir}"
	local t
	for t in aarch64-linux-gnu aarch64-linux-android aarch64-none-linux-gnu; do
		ln -sf "${real}" "${shimdir}/${t}-as"
	done
	if [ -n "${GITHUB_PATH:-}" ]; then
		echo "${shimdir}" >>"${GITHUB_PATH}"
	fi
	export PATH="${shimdir}:${PATH}"

	# Path-independent belt-and-braces: tell clang where to look for
	# <triple>-as, so the alias works even when this script's PATH is a
	# different process than the one kbuild runs in.
	if ! grep -q 'as-shims' "${KERNEL_DIR}/Makefile" 2>/dev/null; then
		{
			echo ''
			echo '# assembler aliases added by patches.sh (clang -no-integrated-as)'
			echo 'KBUILD_CFLAGS += -B'"${shimdir}"
		} >> "${KERNEL_DIR}/Makefile"
	fi
	ok "assembler alias -> ${real}"
}


# Some vendor Makefiles list both a composite object and the members it is
# already built from ("mtk-vcu-y += mtk_vcu.o mtk_vcodec_mem.o" next to
# "obj-... += mtk-vcu.o mtk_vcodec_mem.o").  kbuild then links the same .o
# twice and the final lld link aborts with "duplicate symbol".
dedupe_vendor_obj_lists() {
	group "Deduplicating vendor obj lists"
	python3 - "$KERNEL_DIR" <<'PYEOF'
import os, re, sys

root = sys.argv[1]
obj_re = re.compile(r'^([ \t]*)((?:obj|lib|build)-(?:(?:y|m)|\$[^\s=]+)?[ \t]*\+?=[ \t]*)([^#\n]*)$')
def_re = re.compile(r'^[ \t]*([A-Za-z0-9_.\-]+)-(?:y|objs)[ \t]*[:+]?=[ \t]*(.*)$')
token = re.compile(r'([A-Za-z0-9_.\-]+\.o)')

def logical(text):
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        raw, joined = [lines[i]], lines[i]
        while joined.endswith('\\') and i + 1 < len(lines):
            joined = joined[:-1].rstrip() + ' ' + lines[i + 1].lstrip()
            i += 1
            raw.append(lines[i])
        yield i, joined, raw
        i += 1

total = 0
for dirpath, dirnames, files in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ('out', '.git', '.repo')]
    for f in files:
        if f not in ('Makefile', 'Kbuild'):
            continue
        path = os.path.join(dirpath, f)
        try:
            text = open(path, encoding='utf-8', errors='surrogateescape').read()
        except OSError:
            continue
        rows = list(logical(text))
        members = {}
        for _, joined, _ in rows:
            m = def_re.match(joined)
            if m:
                members.setdefault(m.group(1), set()).update(token.findall(m.group(2)))
        out, changed = text.split('\n'), False
        for end, joined, raw in rows:
            m = obj_re.match(joined)
            if not m:
                continue
            items = token.findall(m.group(3))
            if len(items) < 2:
                continue
            comps = {i[:-2] for i in items}
            dup = sorted({i for i in items if any(i in members.get(c, ()) for c in comps)})
            if not dup:
                continue
            for d in dup:
                joined = re.sub(r'(?<![A-Za-z0-9_.\-])' + re.escape(d) + r'(?=\s|\\|$)', '', joined)
            out[end - len(raw) + 1:end + 1] = [re.sub(r'[ \t]+$', '', joined)]
            changed = True
            total += len(dup)
            print('  %s: dropped %s' % (os.path.relpath(path, root), ', '.join(dup)))
        if changed:
            open(path, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(out))
print('  redundant object references dropped: %d' % total)
PYEOF
	endgroup
}


# Symbols that the public drop still references but no longer defines.  Each
# one is a vendor helper that used to live in a private tree; the call sites are
# kept, so the final link fails with "undefined symbol" until somebody answers
# for them.  Stubbed implementations go into their own directory so they are
# compiled exactly once.
install_symbol_stubs() {
	group "Defining symbols the drop left undefined"
	local dir="${KERNEL_DIR}/drivers/misc/mediatek/oplus_drop_stubs"
	mkdir -p "$dir"
	cat > "$dir/Makefile" <<'MKEOF'
obj-y += stubs.o
MKEOF
	cat > "$dir/stubs.c" <<'CEOF'
/* Implementations of vendor helpers whose sources are absent from the drop. */
#include <linux/types.h>
#include <linux/kernel.h>
#include <linux/string.h>

#ifndef __HAVE_ARCH_STPCPY
/* lib/string.c lost this along with the rest of the OPPO additions. */
char *stpcpy(char *dest, const char *src)
{
	char *d = dest;

	while ((*d = *src) != '\0') {
		d++;
		src++;
	}

	return d;
}
#endif

unsigned int get_eng_version(void)
{
	/* 0 == user build; AGING (1) / FACTORY (2) would take vendor paths that
	 * are not present in the public drop. */
	return 0;
}

bool oplus_daily_build(void)
{
	return false;
}

int phx_is_system_boot_completed(void)
{
	return 1;
}
CEOF
	if ! grep -q 'oplus_drop_stubs/' "${KERNEL_DIR}/drivers/misc/mediatek/Makefile"; then
		printf '\nobj-y += oplus_drop_stubs/\n' >> "${KERNEL_DIR}/drivers/misc/mediatek/Makefile"
	fi
	ok "symbol stubs -> drivers/misc/mediatek/oplus_drop_stubs"
	endgroup
}

# --------------------------------------------------------------------- main ---

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
	sanitize|features|stubs|repair|buildfix|dedupe|symstubs|aslink|all) ;;
	*) set -- all ;;
	esac

	case "${1:-all}" in
		susfs)        susfs_apply ;;
		path_umount)  path_umount_apply ;;
		hide_stuff)   hide_stuff_apply ;;
		hooks)        hooks_patch_apply ;;
		sanitize)     sanitize_public_tree ;;
		features)     neutralize_stripped_hooks ;;
		repair)       repair_stripped_upstream ;;
		aslink)       link_arm_assembler ;;
		buildfix)     freshen_vendor_build ;;
		symstubs)     install_symbol_stubs ;;
		dedupe)       dedupe_vendor_obj_lists ;;
		stubs)        install_private_stubs ;;
		kpm)          kpm_patch_image "$2" ;;
		all)
			# Do this first: the parser runs in the build step, and any
			# Kconfig that still points at a stripped private directory
			# aborts the whole build before a single file is compiled.
			sanitize_public_tree

			# The drop keeps call sites but not the code behind them;
			# both of these must run before the first compile.
			neutralize_stripped_hooks
			install_private_stubs
			repair_stripped_upstream
			freshen_vendor_build
			install_symbol_stubs
			dedupe_vendor_obj_lists

			# Order matters and this is the tested one (4.19 + SukiSU builtin
			# + SUSFS 1.5.5, no rejects):
			#   path_umount and the hook patches both key off textual anchors
			#   in files that SUSFS later rewrites, so they go first.
			# clang needs a <target>-as alias before the first compile.
			link_arm_assembler

			if is_true "${ENABLE_PATH_UMOUNT:-false}"; then path_umount_apply; fi

			# Driven by the *resolved* hook mode, not the raw setting, so that
			# KSU_HOOK_MODE=auto on a pre-GKI kernel still gets its hooks
			# patched in rather than only getting the Kconfig symbol set.
			if [ "${KSU_VARIANT:-none}" != "none" ] &&
			   [ "${KSU_HOOK_MODE_RESOLVED:-}" = "manual" ]; then
				hooks_patch_apply
			fi

			if is_true "${ENABLE_SUSFS:-false}";      then susfs_apply;      fi
			if is_true "${ENABLE_HIDE_STUFF:-false}"; then hide_stuff_apply; fi
			;;
		*) die "unknown patch step '$1'" ;;
	esac
fi
#（注：内容由AI生成）
