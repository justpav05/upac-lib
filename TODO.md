<h1 align="center">✅ TODO</h1> 

Near-term, concrete items. See `ROADMAP.md` for the bigger picture.

## upac-cli

- `user/upac-cli/data/` (`.desktop`, `upac-mime.xml`, `.policy`) reference `Icon=upac`/`icon_name=upac`,
  but there's no actual icon asset (SVG/PNG) yet, and no install step wiring it into
  `/usr/share/icons/hicolor/...`. Needs real artwork before packaging.

## upac-lib

Test-coverage pass in progress. The entire non-command core is covered (`errors.rs`/`lock.rs`/
`search.rs`/`fs.rs`/`orchestrator/*`/`database/*`/`deploy/*`/`scripts/*`/`composefs/*`/`config/*`/
`boot/*`/`plugin/decoder/{error,manifest,triggers}.rs`/`plugin/boot/{error,manifest}.rs`), except
`plugin/decoder/unpack.rs`/`plugin/decoder/mod.rs`/`plugin/boot/mod.rs` (need a real dlopen'd/
`builtin-*` plugin) and `deploy/esp.rs` (real mount table) — both explicit, justified skips. Every
`mutated`/`unmutated` command's own `<Command>Error` enum is also now covered (inline tests next to
each `error.rs`, since `mutated`/`unmutated` aren't `pub`) — only each variant's own logic, not the
macro-generated `Common(...)` delegation shared with `errors.rs`'s already-tested `CommonError`.
Remaining: the `Stage::run()` bodies themselves — each needs a real composefs `Repository`/`Deploy`/
database in context, likely out of scope for unit tests unless a pure-logic helper turns out to be
extractable.

**`genesis`'s `system/` mechanism is done**: `ImportSystemStage` requires `<source>/system/` (a
literal 1:1 mirror of the target's real `/usr`, sibling to the package archives —
`EnumeratePackagesStage` already skips it, it only looks at files) to contain
`lib/systemd/system/composefs-setup-root.service` (hard error, `SetupError::
ComposefsSetupRootUnitNotFound`, if missing), imports the whole tree into `PrefixTree`, and creates
the unit's `*.target.wants/` enablement symlink itself. This is also how a built `up`/`upac-lib`/
booters gets onto a genesis'd disk at all — genesis never installs itself automatically, whoever
assembles `--source` has to place it under `system/` too, same assumption already made for the
systemd-boot/rEFInd binaries. Confirmed `composefs-setup-root`'s own hardcoded expectations already
match upac's on-disk layout exactly (repo at `composefs/`, per-deploy state at `state/deploy/<hex>/`,
`composefs=<hex>` cmdline karg) — no restructuring was needed, only the unit + the `system/` plumbing.
Still unresolved: whether upac ships/packages the `composefs-setup-root` binary itself or expects it
to already exist on the source distro (same open question as the systemd-boot/rEFInd binaries).

**Booter ABI redesign — decided this session, execution in progress file-by-file under direct
supervision (no batch edits).** Four canonical plugin responsibilities:

1. Plugin sets itself for one-time boot (`set_one_shot`) — done.
2. Plugin sets itself for persistent boot (`confirm_boot`) — done, including UKI's `to.efi`↔
   `from.efi` file swap (needed a new `esp_mount_point` parameter on `confirm_boot`, added this
   session; the swap only fires when the confirmed `entry_name` is the `to` slot specifically).
3. Plugin installs itself onto the ESP (`install`) — done for grub (real `grub-install
   --removable --no-nvram` + a minimal `blscfg` `grub.cfg`), no-op for the other 3.
4. Plugin declares where its own pre-built loader binary lives in the source package tree
   (`esp_loader_source`) — done, stays a separate passive query (only genesis can reach the
   composefs tree to copy the bytes out, plugins can't do this step themselves).

**`write_boot_entry` must search only for the resource type the selected plugin needs, not
autonomously scan everything and guess.** Right now (`lib/lib/src/boot/mod.rs`) it calls
`get_boot_resources` unconditionally, takes whichever single boot resource exists in the tree
(Type1/Type2/`UsrLibModulesVmLinuz`), and only errors if more than one is found total — completely
independent of which plugin was actually selected. This is the case in all 6 call sites:
`lib/lib/src/boot/mod.rs` itself, `mutated/{files,installer,uninstaller,update,rollback}/checkout.rs`,
and `lib/setup/src/genesis/entry.rs`. Needs to take the (now always-explicit) plugin name and require
specifically: `uki` → `Type2` only; `grub`/`systemd-boot`/`rEFInd` → `Type1`/`UsrLibModulesVmLinuz`
only — hard error if that type isn't present, even if a different type is. This also means
`resolve_boot_plugin` must run before `write_boot_entry` everywhere — today the 5 ordinary
`checkout.rs` stages call it after (only genesis already has the order right).
