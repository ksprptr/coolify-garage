#!/bin/sh
set -e

sed -e "s|__RPC_SECRET__|${RPC_SECRET}|g" \
    -e "s|__ADMIN_TOKEN__|${ADMIN_TOKEN}|g" \
    /etc/garage.toml.template > /etc/garage.toml

CAPACITY="${GARAGE_CAPACITY:-64G}"
ZONE="${GARAGE_ZONE:-dc1}"
STARTUP_TIMEOUT="${GARAGE_STARTUP_TIMEOUT:-60}"

# Start server in background
/garage server &
SERVER_PID=$!

# Forward shutdown signals to the server so it can flush and exit cleanly
trap 'kill -TERM "$SERVER_PID" 2>/dev/null' TERM INT

# Wait for local RPC to come up, but never forever
i=0
until /garage status >/dev/null 2>&1; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Garage server process died during startup." >&2
    wait "$SERVER_PID" || exit $?
    exit 1
  fi
  i=$((i + 2))
  if [ "$i" -ge "$STARTUP_TIMEOUT" ]; then
    echo "Timed out after ${STARTUP_TIMEOUT}s waiting for garage to start." >&2
    kill -TERM "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    exit 1
  fi
  echo "Waiting for garage to start locally... (${i}s)"
  sleep 2
done

# `node id -q` prints <hex pubkey>@<rpc_public_addr>, but `layout assign`
# expects the hex node id (or a prefix of it) on its own.
NODE_ID=$(/garage node id -q | cut -d@ -f1)
NODE_SHORT=$(echo "$NODE_ID" | cut -c1-16)

# Assign cluster layout on first boot only; on redeploy the layout is already
# in the metadata volume and this whole block is skipped.
if /garage status | grep "^${NODE_SHORT}" | grep -q "NO ROLE ASSIGNED"; then
  echo "Assigning layout for ${NODE_SHORT} with capacity $CAPACITY (zone $ZONE)..."
  if /garage layout assign -z "$ZONE" -c "$CAPACITY" "$NODE_ID"; then
    LAYOUT_VERSION=$(/garage layout show | sed -n 's/^Current cluster layout version: //p')
    if /garage layout apply --version "$((LAYOUT_VERSION + 1))"; then
      echo "Layout applied (version $((LAYOUT_VERSION + 1)))."
    else
      echo "WARNING: 'garage layout apply' failed; node has no role yet." >&2
    fi
  else
    echo "WARNING: 'garage layout assign' failed; node has no role yet." >&2
  fi
else
  echo "Layout already set for ${NODE_SHORT}, skipping."
fi

# Hand control back to the server process
EXIT_CODE=0
wait "$SERVER_PID" || EXIT_CODE=$?
exit "$EXIT_CODE"
