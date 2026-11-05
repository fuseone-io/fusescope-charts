#!/usr/bin/env bash
# Builds the fusescope chart's dependencies, nested ones first, packages it
# into the directory given (default /tmp/fusescope-package), and fails if
# the package lacks clickhouse's zookeeper or holds a path twice.
#
# A file:// dependency is packaged as its directory stands, and the .tgz of
# a chart's dependencies are not committed (.gitignore): without the
# clickhouse build, fusescope shipped clickhouse without zookeeper, and a
# default install could not migrate its schema. zookeeper's own dependency,
# common, is committed as a directory, so zookeeper is not built (building
# it would add common a second time, as a .tgz).
set -euo pipefail

out=${1:-/tmp/fusescope-package}
helm dependency build --skip-refresh charts/clickhouse
helm dependency build --skip-refresh charts/fusescope

rm -rf "$out"
mkdir -p "$out"
helm package charts/fusescope -d "$out" >/dev/null
pkg=$(ls "$out"/fusescope-*.tgz)

# A listing in a file, not a pipe: with pipefail, grep -q closing the pipe
# early fails tar.
tar tzf "$pkg" >"$out/listing.txt"
status=0
for path in \
	fusescope/charts/clickhouse/charts/zookeeper/Chart.yaml \
	fusescope/charts/clickhouse/charts/zookeeper/charts/common/Chart.yaml; do
	if ! grep -Fxq "$path" "$out/listing.txt"; then
		echo "::error::$pkg lacks $path"
		status=1
	fi
done
duplicates=$(sort "$out/listing.txt" | uniq -d)
if [ -n "$duplicates" ]; then
	echo "::error::$pkg holds $(wc -l <<<"$duplicates") paths twice, e.g. $(head -1 <<<"$duplicates")"
	status=1
fi
[ "$status" -eq 0 ] && echo "$pkg: zookeeper packaged, no duplicate path"
exit "$status"
