#!/bin/sh
# Black-box verification of the stack. Run from the infra repo root with the stack already up.
# Exit status is 0 only when every check passes.
set -u

cd "$(dirname "$0")" || exit 2

PASS=0
FAIL=0
WAIT_SECONDS=${VERIFY_WAIT:-120}
DOCS_DIR=${DOCS_DIR:-../test-simple-stock-flow-docs}
REQUIRED_KEYS="APP_PORT CORS_ORIGINS JWT_LIFETIME_MINUTES DB_DATABASE DB_USERNAME DB_PASSWORD DB_ROOT_PASSWORD APP_KEY JWT_SIGNING_KEY ADMIN_EMAIL ADMIN_PASSWORD"
SECRET_KEYS="DB_PASSWORD DB_ROOT_PASSWORD APP_KEY JWT_SIGNING_KEY ADMIN_EMAIL ADMIN_PASSWORD"
LOUD_KEYS="DB_DATABASE DB_USERNAME DB_PASSWORD DB_ROOT_PASSWORD APP_KEY JWT_SIGNING_KEY ADMIN_EMAIL ADMIN_PASSWORD"

FILLED=$(mktemp)
LOGS=$(mktemp)
trap 'rm -f "$FILLED" "$FILLED.minus" "$LOGS"' EXIT

ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check() {
  name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi
}
summary() {
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# 1. Repository layout (article V: no DDL here; article IX: no secrets here)

example_has_all_keys() {
  for k in $REQUIRED_KEYS; do grep -q "^$k=" .env.example || return 1; done
}
example_secrets_empty() {
  ! grep -qE "^($(echo "$SECRET_KEYS" | tr ' ' '|'))=." .env.example
}
no_sql_files() {
  [ -z "$(find . -name '*.sql' -not -path './.git/*')" ]
}
no_ddl_text() {
  ! grep -rIiE 'create (table|database|schema)' --exclude-dir=.git --exclude=verify.sh --exclude=README.md .
}
db_port_not_published() {
  ! grep -qE '3306:3306' docker-compose.yml
}
only_one_published_port() {
  [ "$(grep -c '^ *ports:' docker-compose.yml)" -eq 1 ]
}
dev_override_publishes_db() {
  grep -q '3306' docker-compose.dev.yml
}

check "compose file exists" test -f docker-compose.yml
check "dev override exists" test -f docker-compose.dev.yml
check ".env.example declares every key" example_has_all_keys
check ".env.example has no secret value" example_secrets_empty
check ".env is git-ignored" grep -qx '\.env' .gitignore
check "no .sql file in the repo" no_sql_files
check "no DDL text in the repo" no_ddl_text
check "base compose does not publish the database port" db_port_not_published
check "base compose publishes exactly one port" only_one_published_port
check "dev override publishes the database port" dev_override_publishes_db

# 2. Compose contract: a missing secret must fail loudly and name the variable

sed 's/=$/=x/' .env.example >"$FILLED" 2>/dev/null

compose_valid() {
  docker compose --env-file "$FILLED" config -q
}
missing_key_fails_loudly() {
  key=$1
  grep -v "^$key=" "$FILLED" >"$FILLED.minus"
  out=$(env -u "$key" docker compose --env-file "$FILLED.minus" config 2>&1) && return 1
  printf '%s' "$out" | grep -q "$key"
}

check "compose file is valid with every variable set" compose_valid
for key in $LOUD_KEYS; do
  check "compose fails naming $key when it is missing" missing_key_fails_loudly "$key"
done

if [ "$FAIL" -ne 0 ]; then
  echo "static checks failed; the running stack was not touched"
  summary
  exit 1
fi

# 3. Running stack

[ -f .env ] || {
  fail ".env exists (cp .env.example .env and fill it)"
  summary
  exit 1
}
set -a
# shellcheck disable=SC1091
. ./.env
set +a

health_of() {
  id=$(docker compose ps -q "$1" 2>/dev/null)
  [ -n "$id" ] || {
    echo missing
    return 0
  }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id"
}
wait_healthy() {
  svc=$1
  waited=0
  [ "$(health_of "$svc")" != missing ] || return 1
  while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    [ "$(health_of "$svc")" = healthy ] && return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

for svc in db api app; do
  check "service $svc is healthy" wait_healthy "$svc"
done

if [ "$FAIL" -ne 0 ]; then
  echo "stack is not healthy; HTTP checks skipped"
  summary
  exit 1
fi

app_wget() { docker compose exec -T app wget "$@" 2>&1; }
status_of() { app_wget -S -O /dev/null "$@" | grep -m1 'HTTP/' | awk '{print $2}'; }
JSON='--header=Content-Type: application/json'

api_health_ok() { [ "$(app_wget -qO- http://api:8000/health)" = '{"status":"ok"}' ]; }
anonymous_products_is_401() { [ "$(status_of http://localhost/api/products)" = 401 ]; }
anonymous_products_body_empty() { app_wget -S -O - http://localhost/api/products | grep -qi 'content-length: 0'; }
anonymous_register_is_401() { [ "$(status_of "$JSON" --post-data='{}' http://localhost/api/auth/register)" = 401 ]; }
unknown_route_is_empty_404() {
  [ "$(status_of http://localhost/api/no-such-route)" = 404 ] &&
    app_wget -S -O - http://localhost/api/no-such-route | grep -qi 'content-length: 0'
}

check "api answers /health with the contract body" api_health_ok
check "anonymous GET /api/products is 401" anonymous_products_is_401
check "the 401 has an empty body" anonymous_products_body_empty
check "anonymous POST /api/auth/register is 401" anonymous_register_is_401
check "unknown /api route is an empty 404" unknown_route_is_empty_404

# 4. Schema, seed and admin created by the service itself

login_response() {
  body=$(printf '{"username":"%s","password":"%s"}' "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
  app_wget -qO- "$JSON" --post-data="$body" http://localhost/api/auth/login
}
token_of() { printf '%s' "$1" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'; }
api_get() { app_wget -qO- "--header=Authorization: Bearer $TOKEN" "http://localhost$1"; }

LOGIN=$(login_response)
TOKEN=$(token_of "$LOGIN")

login_returns_token() { [ -n "$TOKEN" ]; }
login_role_is_admin() { printf '%s' "$LOGIN" | grep -q '"role":"admin"'; }
login_hides_hash() { ! printf '%s' "$LOGIN" | grep -qiE 'argon2|password'; }
category_names() { api_get /api/categories | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | paste -sd, -; }
category_count() { api_get /api/categories | grep -o '"id"' | wc -l | tr -d ' '; }
categories_in_contract_order() { [ "$(category_names)" = "Electricidad,Fontanería,General,Herramientas,Pinturas" ]; }
five_categories() { [ "$(category_count)" -eq 5 ]; }
page_size_is_capped() { api_get '/api/products?size=999' | grep -q '"size":100'; }
page_has_total_pages() { api_get '/api/products' | grep -q '"totalPages":'; }

check "the bootstrap admin can log in" login_returns_token
check "login reports role admin" login_role_is_admin
check "login never exposes a hash or the password" login_hides_hash
check "categories come in contract order, accents unescaped" categories_in_contract_order
check "exactly five categories were seeded" five_categories
check "size above the maximum is served as 100" page_size_is_capped
check "paged responses carry totalPages" page_has_total_pages

# 5. Restart keeps the data

restart_keeps_seed() {
  docker compose restart db api || return 1
  wait_healthy db && wait_healthy api && wait_healthy app || return 1
  LOGIN=$(login_response)
  TOKEN=$(token_of "$LOGIN")
  [ "$(category_count)" -eq 5 ]
}
check "restarting db and api keeps the seeded data" restart_keeps_seed

# 6. Logs: correlation and no leaks (RNF-05)

leak_in() {
  grep -qE '\$argon2|eyJ[A-Za-z0-9_-]{10,}' "$1" ||
    { [ -n "${ADMIN_PASSWORD:-}" ] && grep -qF -- "$ADMIN_PASSWORD" "$1"; }
}
leak_detector_catches_dirty_stream() {
  d=$(mktemp)
  printf 'hash=$argon2id$v=19$m=65536\nAuthorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig\n' >"$d"
  leak_in "$d"
  r=$?
  rm -f "$d"
  return $r
}
leak_detector_passes_clean_stream() {
  d=$(mktemp)
  printf 'GET /api/products 401 id=abc\n' >"$d"
  ! leak_in "$d"
  r=$?
  rm -f "$d"
  return $r
}

RID="verify-$(date +%s)-$$"
request_id_is_echoed() {
  app_wget -S -O /dev/null "--header=X-Request-ID: $RID" http://localhost/api/products | grep -qi "x-request-id: $RID"
}
request_id_is_logged() {
  sleep 1
  docker compose logs api --no-color >"$LOGS" 2>&1
  grep -q "$RID" "$LOGS"
}
logs_have_no_secrets() {
  docker compose logs api --no-color >"$LOGS" 2>&1
  ! leak_in "$LOGS"
}

check "leak detector flags a dirty stream" leak_detector_catches_dirty_stream
check "leak detector accepts a clean stream" leak_detector_passes_clean_stream
check "X-Request-ID is echoed in the response" request_id_is_echoed
check "X-Request-ID appears in the api log" request_id_is_logged
check "api log holds no password, hash or token" logs_have_no_secrets

# 7. Progress figure in tasks.md is recomputed from its own table (article X.1)

tasks_file() {
  if [ -f "$DOCS_DIR/spec-laravel/tasks.md" ]; then
    echo "$DOCS_DIR/spec-laravel/tasks.md"
  else
    echo "$DOCS_DIR/spec-python/tasks.md"
  fi
}
progress_matches_table() {
  f=$(tasks_file)
  rows=$(grep -cE '^\| \*\*T-[0-9]+\*\*' "$f")
  done_=$(grep -E '^\| \*\*T-[0-9]+\*\*' "$f" | grep -c '✅')
  declared=$(grep -oE '\*\*[0-9]+ de [0-9]+ hechas' "$f" | head -1)
  [ "$declared" = "**$done_ de $rows hechas" ]
}
check "sibling docs repo is present" test -d "$DOCS_DIR"
check "declared progress equals the progress table" progress_matches_table

summary
