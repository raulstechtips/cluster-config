#!/usr/bin/env bash
#
# Replace the contents of the UAT Infisical database with a copy of production.
#
# Dumps the production database, drops every schema in the target, restores the
# dump into it, and verifies that both sides agree.
#
# The target database must already exist. This script never creates or drops it;
# provisioning is owned by the CNPG Database manifest in apps/cnpg-prod.

set -euo pipefail

NS="${NS:-prod}"
CLUSTER="${CLUSTER:-pg-prod}"
SRC_DB="${SRC_DB:-pg-infisical}"
DST_DB="${DST_DB:-pg-infisical-uat}"
OWNER="${OWNER:-infisical-pg-admin}"
DUMP_DIR="${DUMP_DIR:-/tmp/infisical-dumps}"

usage() {
  cat <<'EOF'
Usage: copy_prod_db.sh [options]

Copy the production Infisical database into the UAT database.

Options:
  --from-latest   Reuse the newest dump in DUMP_DIR instead of dumping again
  -y, --yes       Skip the confirmation prompt
  -h, --help      Show this help

Environment:
  NS         Namespace holding the Postgres cluster   (default: prod)
  CLUSTER    CNPG cluster name                        (default: pg-prod)
  SRC_DB     Database to copy from                    (default: pg-infisical)
  DST_DB     Database to copy into                    (default: pg-infisical-uat)
  OWNER      Role that owns the restored objects      (default: infisical-pg-admin)
  DUMP_DIR   Directory for dump files                 (default: /tmp/infisical-dumps)
EOF
}

FROM_LATEST=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --from-latest) FROM_LATEST=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) printf 'unknown argument: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then BOLD=$'\033[1m'; RED=$'\033[31m'; RESET=$'\033[0m'
else BOLD=""; RED=""; RESET=""; fi

step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n%sFAILED: %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# Run a single query against a database and return the bare result.
psql_q() {
  kubectl exec -n "$NS" "$PRIMARY" -c postgres -- \
    psql -U postgres -d "$1" -tAc "$2"
}

# --------------------------------------------------------------------- checks

[ "$SRC_DB" = "$DST_DB" ] && die "SRC_DB and DST_DB are both '$SRC_DB'; that would destroy the source"

step "Preflight"

PRIMARY="$(kubectl get cluster -n "$NS" "$CLUSTER" -o jsonpath='{.status.currentPrimary}')"
[ -n "$PRIMARY" ] || die "could not resolve the primary of cluster '$CLUSTER' in namespace '$NS'"
info "primary        $PRIMARY"
info "source         $SRC_DB"
info "target         $DST_DB  (owner $OWNER)"

exists="$(psql_q postgres "SELECT count(*) FROM pg_database WHERE datname = '$DST_DB';")"
[ "$exists" = "1" ] || die "database '$DST_DB' does not exist; apply its CNPG Database manifest first"

# Restoring into a database that still has clients attached leaves a mixture of
# old and new state that is difficult to diagnose later.
conns="$(psql_q postgres "SELECT count(*) FROM pg_stat_activity WHERE datname = '$DST_DB' AND pid <> pg_backend_pid();")"
if [ "$conns" != "0" ]; then
  die "$conns open connection(s) to '$DST_DB'; scale the UAT deployment down first:
       kubectl scale deploy/infisical-infisical-standalone-infisical -n infisical-uat --replicas=0"
fi
info "connections    0"

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '\nThis drops every schema in %s and replaces it with a copy of %s.\nContinue? [y/N] ' "$DST_DB" "$SRC_DB"
  read -r reply
  case "$reply" in [yY]*) ;; *) echo "aborted"; exit 1 ;; esac
fi

# ----------------------------------------------------------------------- dump

mkdir -p "$DUMP_DIR"

if [ "$FROM_LATEST" -eq 1 ]; then
  step "Selecting most recent dump"
  DUMP="$(ls -t "$DUMP_DIR"/"$SRC_DB"-*.dump 2>/dev/null | head -1 || true)"
  [ -n "$DUMP" ] || die "no dump found in $DUMP_DIR; run without --from-latest"
else
  step "Dumping $SRC_DB"
  DUMP="$DUMP_DIR/$SRC_DB-$(date -u +%Y%m%dT%H%M%SZ).dump"
  # kubectl exec must not allocate a TTY here; it would corrupt the binary stream.
  kubectl exec -n "$NS" "$PRIMARY" -c postgres -- \
    pg_dump -U postgres -d "$SRC_DB" -Fc --no-owner --no-privileges \
    > "$DUMP"
  ln -sf "$(basename "$DUMP")" "$DUMP_DIR/$SRC_DB-latest.dump"
fi

[ -s "$DUMP" ] || die "dump file is empty: $DUMP"
info "dump           $DUMP  ($(du -h "$DUMP" | cut -f1))"

# ---------------------------------------------------------------------- reset

step "Resetting $DST_DB"

# Every non-system schema is dropped rather than a fixed list. Infisical spans
# both public and pgboss, CNPG seeds a user_search function into each database
# it manages, and a future release may introduce further schemas. Anything left
# behind collides with the restore.
kubectl exec -i -n "$NS" "$PRIMARY" -c postgres -- \
  psql -U postgres -d "$DST_DB" -v ON_ERROR_STOP=1 -q -f - <<SQL
DO \$\$
DECLARE s text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace
           WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema'
  LOOP EXECUTE format('DROP SCHEMA %I CASCADE', s); END LOOP;
END
\$\$;
CREATE SCHEMA public AUTHORIZATION "$OWNER";
SQL

schemas="$(psql_q "$DST_DB" "SELECT coalesce(string_agg(nspname, ','), '(none)') FROM pg_namespace WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema';")"
rels="$(psql_q "$DST_DB" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema';")"
info "schemas        $schemas"
info "relations      $rels"
[ "$schemas" = "public" ] || die "expected only 'public' after reset, found '$schemas'"
[ "$rels" = "0" ]         || die "expected 0 relations after reset, found $rels"

# -------------------------------------------------------------------- restore

step "Restoring into $DST_DB"

# --role issues SET ROLE so restored objects belong to the application user
# even though the connection is made as postgres.
kubectl exec -i -n "$NS" "$PRIMARY" -c postgres -- \
  pg_restore -U postgres -d "$DST_DB" \
    --no-owner --no-privileges --role="$OWNER" --exit-on-error \
  < "$DUMP" \
  || die "pg_restore failed; re-run this script rather than retrying the restore on its own"

info "restore        ok"

# --------------------------------------------------------------------- verify

step "Verifying"

counts_sql="SELECT 'migrations=' || (SELECT count(*) FROM infisical_migrations)
        || ' secrets='   || (SELECT count(*) FROM secrets_v2)
        || ' projects='  || (SELECT count(*) FROM projects)
        || ' users='     || (SELECT count(*) FROM users);"

schema_sql="SELECT string_agg(x, ' ' ORDER BY x) FROM (
              SELECT n.nspname || '=' || count(*)::text AS x
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname IN ('public','pgboss')
              GROUP BY n.nspname) t;"

src_counts="$(psql_q "$SRC_DB" "$counts_sql")"
dst_counts="$(psql_q "$DST_DB" "$counts_sql")"
src_schema="$(psql_q "$SRC_DB" "$schema_sql")"
dst_schema="$(psql_q "$DST_DB" "$schema_sql")"

printf '    %-18s %s\n' "$SRC_DB" "$src_counts"
printf '    %-18s %s\n' "$DST_DB" "$dst_counts"
printf '    %-18s %s\n' "$SRC_DB" "$src_schema"
printf '    %-18s %s\n' "$DST_DB" "$dst_schema"

rc=0
if [ "$src_counts" != "$dst_counts" ]; then
  printf '\n%srow counts differ%s\n' "$RED" "$RESET" >&2
  printf 'A write to the source between the dump and this check produces the same\n' >&2
  printf 'result. Re-run the script; if the counts still differ, the restore is bad.\n' >&2
  rc=1
fi
if [ "$src_schema" != "$dst_schema" ]; then
  printf '\n%sschema relation counts differ; the restore is incomplete%s\n' "$RED" "$RESET" >&2
  rc=1
fi

[ "$rc" -eq 0 ] || exit "$rc"

step "Complete"
info "$DST_DB now matches $SRC_DB"
info "dump retained  $DUMP"
info "restart UAT    kubectl scale deploy/infisical-infisical-standalone-infisical -n infisical-uat --replicas=1"
