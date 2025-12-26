#!/bin/bash
set -e

echo "=== FaceFusion Instance Starting ==="

# Setup SSH keys from Vast.ai environment
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "SSH key configured"
fi

# Create workspace
mkdir -p ${WORKSPACE}

# Run provisioning script if provided
if [[ -n "${PROVISIONING_SCRIPT:-}" ]]; then
    echo "Running provisioning script..."
    curl -fsSL "${PROVISIONING_SCRIPT}" | bash
fi

echo "Starting Supervisor..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
