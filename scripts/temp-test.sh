echo "--- Creating temporary folders ---"
mkdir -p /tmp/var/repo
mkdir /tmp/root

echo "--- Adding temporary folders to PATH ---"
export PATH=/tmp/root/bin:$PATH
