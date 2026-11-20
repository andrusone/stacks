"""plexcurator CLI. `mode` in the config decides what a run may do (observe < organize < reclaim);
--dry-run previews any mode and changes nothing. Exit codes: 0 ok/warning, 1 error, 2 error alert.
"""

import argparse
import logging
import os
import re
import sys
import time

from .version import APP_VERSION, SCHEMA_VERSION
from . import (
    alerts,
    backup as B,
    clients,
    collect,
    config,
    db,
    discover,
    layout,
    lifecycle,
    logs,
    probe,
)
from . import radarr_paths, sync as S, validate as V, watchlist

log = logging.getLogger("plexcurator")
QUERIES = os.path.join(os.path.dirname(__file__), "queries.sql")
PREVIEW_ROW_LIMIT = 45


def _clients(cfg):
    plex = clients.Plex(cfg["plex"]["url"], cfg["plex"]["token"])
    rc = cfg["radarr"]
    return plex, clients.Radarr(rc["url"], rc["api_key"]) if rc["url"] else None


def _probe_fn(cfg):
    a = cfg["advanced"]
    return lambda path: (
        probe.run_ffprobe(path, a["ffprobe"]),
        probe.run_mediainfo(path, a["mediainfo"]),
    )


def do_organize(conn, cfg, plex, radarr, dry):
    execute = cfg["mode"] in ("organize", "reclaim") and not dry
    plan = layout.plan_moves(conn, cfg)
    radarr_errors = []
    for p, status in layout.apply_moves(
        conn,
        cfg,
        plan,
        execute,
        radarr,
        plex,
        _probe_fn(cfg),
        radarr_errors=radarr_errors,
    ):
        print(
            f"[{status}] {p['title']} ({p['reason']}): {p['src_file']} -> {p['dst_file']}"
        )
    if radarr_errors:
        print(f"Radarr update failures: {len(radarr_errors)}")
        for error in radarr_errors:
            print(f"ALERT: {error}")
    why = (
        ""
        if execute
        else f" (not applied: {'dry run' if dry else 'mode is ' + cfg['mode']})"
    )
    print(f"{len(plan)} move(s){why}")
    return radarr_errors


def do_reclaim(conn, cfg, plex, radarr, dry, confirm_age_only=False):
    """-> alert text or None."""
    free, total = lifecycle.usage(config.measure_path(cfg))
    st = cfg["storage"]
    print(
        f"free space: {100 * free / total:.1f}% ({lifecycle.human(free)} of {lifecycle.human(total)}); "
        f"reclaim below {st['min_free_pct']}%, to {st['reclaim_to_pct']}%"
    )
    plan, alert = lifecycle.plan(conn, cfg, free, total)
    age_candidates = [c for c in plan if c["age_only"]]
    space_candidates = [c for c in plan if not c["age_only"]]
    print(
        f"age only: {len(age_candidates)} candidate(s), "
        f"{lifecycle.human(sum(c['size'] for c in age_candidates))}"
    )
    print(
        f"space-driven: {len(space_candidates)} candidate(s), "
        f"{lifecycle.human(sum(c['size'] for c in space_candidates))}"
    )
    for c in plan:
        print(
            f"  {'age only' if c['age_only'] else 'space-driven':12} "
            f"{c['rule']:16} {c['size'] / 1e9:7.1f} GB  "
            f"{c['title']} ({c['year']}) - {c['reason']}"
        )
    execute = cfg["mode"] == "reclaim" and not dry
    if confirm_age_only and not execute:
        raise RuntimeError(
            "--confirm-age-only requires reclaim mode and a real reclaim command"
        )
    confirmation_alert = None
    if execute:
        confirmation_alert = lifecycle.age_only_confirmation(
            conn, cfg, plan, confirm=confirm_age_only
        )
        if confirmation_alert:
            print(confirmation_alert)
            execute = False
    print(
        f"{len(plan)} candidate(s)"
        + (
            ""
            if execute or not plan
            else (
                " (not deleted: age-only policy requires confirmation)"
                if confirmation_alert
                else f" (not deleted: {'dry run' if dry else 'mode is ' + cfg['mode']})"
            )
        )
    )
    if plan and execute:
        lifecycle.execute(conn, cfg, plan, plex, radarr)
    return "\n".join(m for m in (alert, confirmation_alert) if m) or None


def do_reclaim_preview(conn, cfg, free, total, all_candidates=False):
    planned, groups = lifecycle.preview_candidates(conn, cfg)
    print(
        f"free space: {100 * free / total:.1f}% "
        f"({lifecycle.human(free)} of {lifecycle.human(total)})"
    )
    print(f"candidate summary: {len(planned)} eligible candidate(s) by folder and rule")
    age_candidates = [c for c in planned if c["age_only"]]
    space_candidates = [c for c in planned if not c["age_only"]]
    print(
        f"age only: {len(age_candidates)} candidate(s), "
        f"{lifecycle.human(sum(c['size'] for c in age_candidates))}"
    )
    print(
        f"space-driven: {len(space_candidates)} candidate(s), "
        f"{lifecycle.human(sum(c['size'] for c in space_candidates))}"
    )
    print("folder | rule | count | total size | oldest age")
    visible_groups = groups if all_candidates else groups[:PREVIEW_ROW_LIMIT]
    if visible_groups:
        for group in visible_groups:
            print(
                f"{group['folder']} | {group['rule']} | {group['count']} | "
                f"{lifecycle.human(group['size'])} | {group['oldest_age_days']}d"
            )
    else:
        print("(no candidate groups)")
    if len(visible_groups) < len(groups):
        print(
            f"... {len(groups) - len(visible_groups)} group(s) omitted; "
            "use --all for the complete summary"
        )

    print("candidates:")
    visible_candidates = planned if all_candidates else planned[:PREVIEW_ROW_LIMIT]
    for index, candidate in enumerate(visible_candidates, 1):
        age = (
            f"age={candidate['age_days']}d since {candidate['age_basis']} "
            f"{candidate['age_since']}; threshold={candidate['age_threshold']} "
            f"(source={candidate['age_source']})"
            if candidate["age_threshold"]
            else f"age={candidate['age_days']}d since {candidate['age_basis']} "
            f"{candidate['age_since']} (source={candidate['age_source']})"
        )
        print(
            f"{index:2d}. {'age only' if candidate['age_only'] else 'space-driven':12} "
            f"{candidate['rule']:16} "
            f"{lifecycle.human(candidate['size']):>8} | "
            f"{candidate['title']} ({candidate['year']}) | {age} | "
            f"folder={candidate['folder']} | {candidate['reason']}"
        )
    if len(visible_candidates) < len(planned):
        print(
            f"... {len(planned) - len(visible_candidates)} candidate(s) omitted; "
            "use --all for the full list"
        )

    space_low = 100.0 * free / total < cfg["storage"]["min_free_pct"]
    if space_low and cfg["mode"] == "reclaim":
        print(
            f"real run would act now: free space is below "
            f"{cfg['storage']['min_free_pct']}%"
        )
    elif space_low:
        print(
            f"real run would not delete now: space is below threshold, "
            f"but mode is {cfg['mode']}"
        )
    elif age_candidates and cfg["mode"] == "reclaim":
        print("real run would act now: age-only reclaim is enabled")
    elif age_candidates:
        print(
            f"real run would not delete now: age-only candidates exist but mode is {cfg['mode']}"
        )
    else:
        print(
            "real run would not act now: space is fine and no age-only candidate is eligible"
        )
    return 0


def run_all(conn, cfg, plex, radarr, dry):
    run_started_at = int(time.time())
    if cfg["folders"]["managed"]:
        made = layout.ensure_tree(cfg, create=not dry)
        if made:
            print(
                f"{'would create' if dry else 'created'} {len(made)} managed folder(s)"
            )
    print("sync:", S.sync(conn, cfg, plex, radarr))
    print("watchlist:", watchlist.sync_watchlist(conn, plex))
    print("discover:", discover.discover(conn, cfg, radarr))
    print("logs:", logs.scan(conn, cfg["advanced"]["plex_log_dir"]))
    radarr_errors = do_organize(conn, cfg, plex, radarr, dry)
    path_check = radarr_paths.check(
        conn,
        cfg,
        radarr,
        fix=cfg["mode"] in ("organize", "reclaim") and not dry,
        moved_before=run_started_at,
    )
    print_radarr_path_check(path_check)
    unidentified = alerts.collect(conn)
    shortfall = do_reclaim(conn, cfg, plex, radarr, dry)
    errors = (
        radarr_errors
        + path_check.findings
        + path_check.errors
        + ([shortfall] if shortfall else [])
    )
    if cfg["alert_unidentified"] == "warn":
        return alerts.publish(cfg, warnings=unidentified, errors=errors)
    return alerts.publish(cfg, errors=unidentified + errors)


def print_radarr_path_check(result):
    if result.skipped_reason:
        print(f"Radarr path check skipped: {result.skipped_reason}")
        return
    print(
        f"Radarr path check: {result.checked} moved movie(s) checked, "
        f"{result.drifted} drift(s), {result.repaired} repaired, "
        f"{result.skipped} without a Radarr match"
    )
    for finding in result.findings:
        print(f"ALERT: {finding}")
    for error in result.errors:
        print(f"ALERT: {error}")


def run_query(conn, name):
    blocks = dict(
        re.findall(
            r"-- name: (\w+)\n(.*?)(?=\n-- name:|\Z)", open(QUERIES).read(), re.S
        )
    )
    if not name or name == "list" or name not in blocks:
        return print("\n".join(blocks)) or 0
    cur = conn.execute(blocks[name])
    print("\t".join(d[0] for d in cur.description))
    for r in cur:
        print("\t".join("" if v is None else str(v) for v in r))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="plexcurator")
    ap.add_argument("-c", "--config", default=os.environ.get("PLEXCURATOR_CONFIG"))
    ap.add_argument(
        "--version",
        action="version",
        version=f"plexcurator {APP_VERSION} (database schema {SCHEMA_VERSION})",
    )
    ap.add_argument(
        "--dry-run", action="store_true", help="preview: change nothing, in any mode"
    )
    ap.add_argument(
        "--preview",
        action="store_true",
        help="reclaim: list all candidates without space thresholds or changes",
    )
    ap.add_argument(
        "--all",
        dest="all_candidates",
        action="store_true",
        help="reclaim preview: show all summary groups and candidates",
    )
    ap.add_argument(
        "--confirm-age-only",
        action="store_true",
        help="reclaim: confirm the pending age-only candidate list and enable its policy",
    )
    ap.add_argument(
        "--offline", action="store_true", help="validate: skip Plex/Radarr connectivity"
    )
    ap.add_argument(
        "--skip-tools",
        action="store_true",
        help="validate: do not require ffprobe/mediainfo yet",
    )
    ap.add_argument(
        "--skip-kometa-backup",
        action="store_true",
        help="backup: skip Kometa so isolated Plex backup checks need no host config",
    )
    ap.add_argument(
        "--selftest",
        action="store_true",
        help="validate: make one unchanged Radarr movie update request",
    )
    ap.add_argument(
        "--fix",
        action="store_true",
        help="radarr-check: repair stale Radarr paths (requires organize or reclaim mode)",
    )
    ap.add_argument(
        "cmd",
        choices=[
            "validate",
            "init-db",
            "init-layout",
            "run",
            "radarr-check",
            "sync",
            "watchlist",
            "discover",
            "logs",
            "organize",
            "reclaim",
            "reclassify",
            "backup",
            "query",
        ],
    )
    ap.add_argument("name", nargs="?", help="query name (see queries.sql) or 'list'")
    a = ap.parse_args(argv)
    if a.selftest and a.cmd != "validate":
        ap.error("--selftest applies only to validate")
    if a.fix and a.cmd != "radarr-check":
        ap.error("--fix applies only to radarr-check")
    if a.fix and a.dry_run:
        ap.error("--fix cannot be combined with --dry-run")
    if a.skip_kometa_backup and a.cmd != "backup":
        ap.error("--skip-kometa-backup applies only to backup")
    if a.confirm_age_only and (
        a.cmd != "reclaim" or a.dry_run or a.preview or a.all_candidates
    ):
        ap.error("--confirm-age-only applies only to a real reclaim command")
    if (a.preview or a.all_candidates) and a.cmd != "reclaim":
        ap.error("--preview and --all apply only to reclaim")
    if a.all_candidates and not (a.preview or a.dry_run):
        ap.error("--all requires --preview or --dry-run reclaim")
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    cfg = config.load(a.config)
    if a.cmd == "validate":
        result = V.report(cfg, online=not a.offline, tools=not a.skip_tools)
        if result or not a.selftest:
            return result
        try:
            clients.Radarr(cfg["radarr"]["url"], cfg["radarr"]["api_key"]).selftest()
        except Exception as e:
            message = f"Radarr write selftest failed: {clients.error_status(e)}"
            log.error("%s", message)
            print(f"ERROR {message}")
            return 1
        print("Radarr write selftest passed (one existing movie updated unchanged)")
        return 0
    if a.cmd == "backup":
        backup_dir = cfg["storage"]["backup_dir"]
        plex_archive = B.backup_with_config(
            cfg["advanced"]["db_path"],
            os.environ.get("PLEX_APPDATA_DIR", B.DEFAULT_PLEX_APPDATA),
            backup_dir,
            cfg["advanced"]["backup_keep"],
        )
        print("backup:", plex_archive)
        if not a.skip_kometa_backup:
            kometa_archive = B.backup_kometa_with_config(
                os.environ.get("KOMETA_CONFIG_PATH", B.DEFAULT_KOMETA_CONFIG),
                os.environ.get("KOMETA_COLLECTIONS_PATH", B.DEFAULT_KOMETA_COLLECTIONS),
                backup_dir,
                os.path.dirname(os.path.abspath(cfg["advanced"]["db_path"])),
            )
            print("Kometa backup:", kometa_archive)
        return 0
    errors, _ = V.validate(cfg, online=False, tools=False)
    if errors:
        print(
            "config invalid (run: plexcurator validate):\n  " + "\n  ".join(errors),
            file=sys.stderr,
        )
        return 1
    if a.cmd == "radarr-check" and a.fix and cfg["mode"] == "observe":
        print("Radarr path repair requires organize or reclaim mode; no changes made")
        return 1
    if a.cmd == "init-layout":
        for d in layout.ensure_tree(cfg, create=not a.dry_run):
            print(("would create " if a.dry_run else "created ") + d)
        return 0
    read_only_command = a.cmd == "radarr-check" and not a.fix
    read_only_preview = a.cmd == "reclaim" and (
        a.preview or (a.dry_run and a.all_candidates)
    )
    if not read_only_preview and not read_only_command:
        os.makedirs(os.path.dirname(cfg["advanced"]["db_path"]), exist_ok=True)
    try:
        if read_only_preview or read_only_command:
            conn = db.connect_read_only(cfg["advanced"]["db_path"])
        else:
            conn = db.connect(
                cfg["advanced"]["db_path"], backup_dir=cfg["storage"]["backup_dir"]
            )
    except db.SchemaError as e:
        print(f"plexcurator: {e}", file=sys.stderr)
        return 1
    try:
        if a.cmd == "init-db":
            print(
                f"database ready: {cfg['advanced']['db_path']} (schema {SCHEMA_VERSION})"
            )
        elif a.cmd == "query":
            return run_query(conn, a.name)
        elif a.cmd == "reclassify":
            print("reclassified:", collect.reclassify(conn, cfg))
        else:
            if read_only_preview:
                free, total = lifecycle.usage(config.measure_path(cfg))
                return do_reclaim_preview(
                    conn, cfg, free, total, all_candidates=a.all_candidates
                )
            plex, radarr = _clients(cfg)
            if a.cmd == "run":
                return run_all(conn, cfg, plex, radarr, a.dry_run)
            if a.cmd == "radarr-check":
                result = radarr_paths.check(conn, cfg, radarr, fix=a.fix)
                print_radarr_path_check(result)
                if result.errors or result.drifted > result.repaired:
                    return 2
            if a.cmd == "sync":
                print(S.sync(conn, cfg, plex, radarr))
            elif a.cmd == "watchlist":
                print(watchlist.sync_watchlist(conn, plex))
            elif a.cmd == "discover":
                print(discover.discover(conn, cfg, radarr))
            elif a.cmd == "logs":
                print(logs.scan(conn, cfg["advanced"]["plex_log_dir"]))
            elif a.cmd == "organize":
                radarr_errors = do_organize(conn, cfg, plex, radarr, a.dry_run)
                if radarr_errors:
                    return alerts.publish(cfg, errors=radarr_errors)
            elif a.cmd == "reclaim":
                return alerts.publish(
                    cfg,
                    errors=[
                        m
                        for m in [
                            do_reclaim(
                                conn,
                                cfg,
                                plex,
                                radarr,
                                a.dry_run,
                                a.confirm_age_only,
                            )
                        ]
                        if m
                    ],
                )
    except Exception as e:
        log.error("%s failed: %s", a.cmd, e)
        return 1
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
