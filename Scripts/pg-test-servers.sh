#!/usr/bin/env bash
#
# Starts/stops the PostgreSQL servers used by PostgresKit's integration tests.
#
#   Scripts/pg-test-servers.sh up            start both servers, wait until ready, load test data
#   Scripts/pg-test-servers.sh down          stop and remove both servers
#   Scripts/pg-test-servers.sh psql <port>   open psql against the server on <port>
#
# sp-pg12: postgres:12, port 55412, SSL off
# sp-pg18: postgres:18, port 55418, SSL on (self-signed certificate generated at startup)
#
# Both use user pgkit_test / password pgkit / database pgkit_test (the user is a superuser).

set -euo pipefail

USER_NAME=pgkit_test
PASSWORD=pgkit
DB_NAME=pgkit_test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DATA="$SCRIPT_DIR/../Frameworks/PostgresKit/Resources/TestData.sql"

start_server() {
	local name=$1 image=$2 port=$3
	shift 3

	if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
		docker start "$name" > /dev/null
		return
	fi

	docker run -d --name "$name" \
		-e POSTGRES_USER="$USER_NAME" \
		-e POSTGRES_PASSWORD="$PASSWORD" \
		-e POSTGRES_DB="$DB_NAME" \
		-p "127.0.0.1:$port:5432" \
		"$@" > /dev/null
}

wait_ready() {
	local name=$1 tries=0

	# The image's init phase restarts the server once, so require two consecutive successes
	local ok=0
	while [ $ok -lt 2 ]; do
		if docker exec "$name" pg_isready -U "$USER_NAME" -d "$DB_NAME" -h 127.0.0.1 -q 2> /dev/null; then
			ok=$((ok + 1))
		else
			ok=0
		fi

		tries=$((tries + 1))
		if [ $tries -gt 120 ]; then
			echo "error: $name did not become ready" >&2
			exit 1
		fi

		sleep 1
	done
}

load_test_data() {
	local name=$1

	# Session settings the integration tests' expected values depend on
	docker exec -i "$name" psql -q -v ON_ERROR_STOP=1 -U "$USER_NAME" -d "$DB_NAME" \
		-c "ALTER DATABASE $DB_NAME SET timezone TO 'Europe/London'" \
		-c "ALTER DATABASE $DB_NAME SET datestyle TO 'ISO, DMY'" > /dev/null

	# TestData.sql drops and recreates its table, so this is idempotent
	docker exec -i "$name" psql -q -v ON_ERROR_STOP=1 -U "$USER_NAME" -d "$DB_NAME" < "$TEST_DATA" > /dev/null
}

case "${1:-}" in
	up)
		start_server sp-pg12 postgres:12 55412 postgres:12

		# Generate a self-signed certificate at startup, then hand over to the stock entrypoint
		start_server sp-pg18 postgres:18 55418 --entrypoint bash postgres:18 -c '
			set -e
			mkdir -p /etc/pgkit-ssl
			if [ ! -f /etc/pgkit-ssl/server.crt ]; then
				openssl req -new -x509 -days 365 -nodes -subj "/CN=localhost" \
					-keyout /etc/pgkit-ssl/server.key -out /etc/pgkit-ssl/server.crt
			fi
			chown postgres:postgres /etc/pgkit-ssl/server.key /etc/pgkit-ssl/server.crt
			chmod 600 /etc/pgkit-ssl/server.key
			exec docker-entrypoint.sh postgres -c ssl=on \
				-c ssl_cert_file=/etc/pgkit-ssl/server.crt \
				-c ssl_key_file=/etc/pgkit-ssl/server.key
		'

		wait_ready sp-pg12
		wait_ready sp-pg18

		load_test_data sp-pg12
		load_test_data sp-pg18

		echo "PostgreSQL 12 (no SSL) on 127.0.0.1:55412, PostgreSQL 18 (SSL) on 127.0.0.1:55418"
		;;
	down)
		docker rm -f sp-pg12 sp-pg18 > /dev/null 2>&1 || true
		;;
	psql)
		port=${2:?usage: pg-test-servers.sh psql <port>}
		case "$port" in
			55412) name=sp-pg12 ;;
			55418) name=sp-pg18 ;;
			*) echo "unknown port $port" >&2; exit 1 ;;
		esac
		exec docker exec -it -e PGPASSWORD="$PASSWORD" "$name" psql -U "$USER_NAME" -d "$DB_NAME"
		;;
	*)
		echo "usage: $0 up|down|psql <port>" >&2
		exit 1
		;;
esac
