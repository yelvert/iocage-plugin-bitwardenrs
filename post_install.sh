#!/bin/sh

set -euo pipefail

# https://www.truenas.com/community/threads/how-to-build-your-own-bitwarden_rs-jail.81389/

REPO="https://github.com/dani-garcia/bitwarden_rs"
BITWARDEN_RS_VERSION="1.17.0"

USERNAME="bitwarden"
USERID=345
RUST_HOME="/usr/local/etc/rust"

# some npm dependency will need to have python2.7 and will fail with python3
ln -s /usr/local/bin/python2.7 /usr/local/bin/python

# Create user 'bitwarden'
pw add group -n "${USERNAME}" -g $USERID
pw add user -n "${USERNAME}" -s /bin/nologin -u $USERID -g $USERID -m

RUSTUP_HOME="${RUST_HOME}"
export RUSTUP_HOME
CARGO_HOME="${RUST_HOME}"
export CARGO_HOME
curl https://sh.rustup.rs -sSf | sh -s -- -y --no-modify-path

. "${RUST_HOME}/env"

RUSTUP_SHIM="/usr/local/bin/rustup_shim"
cat <<-EOF > "${RUSTUP_SHIM}"
#!/bin/sh
RUSTUP_HOME=${RUST_HOME} exec "${RUST_HOME}/bin/\${0##*/}" "\$@"
EOF
chmod +x "${RUSTUP_SHIM}"

for x in ${RUST_HOME}/bin/*; do
  ln -s "${RUSTUP_SHIM}" "/usr/local/bin/$(basename $x)"
done

HOME_DIR="/home/${USERNAME}"
BITWARDEN_RS_DIR="${HOME_DIR}/bitwarden_rs"

su -m "${USERNAME}" -c "git clone -b ${BITWARDEN_RS_VERSION} --single-branch --depth 1 ${REPO} ${BITWARDEN_RS_DIR}"
cd "${BITWARDEN_RS_DIR}"
cargo build --features sqlite --release
cargo install diesel_cli --no-default-features --features sqlite-bundled

WEB_VAULT_REPO="https://github.com/bitwarden/web.git"
WEB_VAULT_PATH="${HOME_DIR}/web-vault"
WEB_VAULT_VERSION="v2.16.1"

su -m "${USERNAME}" -c "git clone -b ${WEB_VAULT_VERSION} --single-branch --depth 1 ${WEB_VAULT_REPO} ${WEB_VAULT_PATH}"
cd "${WEB_VAULT_PATH}"
curl https://raw.githubusercontent.com/dani-garcia/bw_web_builds/master/patches/${WEB_VAULT_VERSION}.patch > "${WEB_VAULT_VERSION}.patch"
git apply "${WEB_VAULT_VERSION}.patch" -v

npm run sub:init
npm install @angular/compiler-cli
npm install
npm run dist

INSTALL_DIR="/usr/local/etc/bitwardenrs"
DATA_FOLDER="/mnt/bitwardenrs"
cp -r "${BITWARDEN_RS_DIR}/target/release" "${INSTALL_DIR}"
cp -r "${WEB_VAULT_PATH}/build" "${INSTALL_DIR}/web-vault"
chown -R "${USERNAME}:${USERNAME}" "${INSTALL_DIR}"
mkdir "${DATA_FOLDER}"
chown -R "${USERNAME}:${USERNAME}" /mnt/bitwardenrs

cat <<-EOF > /usr/local/etc/rc.d/bitwardenrs
#!/bin/sh

# PROVIDE: bitwardenrs
# REQUIRE: LOGIN DAEMON NETWORKING
# KEYWORD: jail rust

. /etc/rc.subr

name="bitwardenrs"
rcvar="bitwardenrs_enable"
pidfile="/var/run/\${name}.pid"
task="./bitwarden_rs"
procname="\${task}"
command="/usr/sbin/daemon"
command_args="-u ${USERNAME} -p \${pidfile} \${task}"
bitwardenrs_chdir=/usr/local/etc/bitwardenrs

load_rc_config \$name

bitwardenrs_enable=\${bitwardenrs_enable:-"NO"}
bitwardenrs_default_data=\${bitwardenrs_default_data:-""}
bitwardenrs_default_admin_token=\${bitwardenrs_default_admin_token:-""}

export DATA_FOLDER="\${bitwardenrs_default_data}"
export ADMIN_TOKEN="\${bitwardenrs_default_admin_token}"

run_rc_command "\$1"
EOF

admin_token="$(openssl rand -base64 48)"

sysrc -f /etc/rc.conf bitwardenrs_enable="YES"
sysrc -f /etc/rc.conf bitwardenrs_default_data="${DATA_FOLDER}"
sysrc -f /etc/rc.conf bitwardenrs_default_admin_token="${admin_token}"

echo "The initial password for the Admin is: ${admin_token}" > /root/PLUGIN_INFO
echo "The default data directory is: ${DATA_FOLDER}" >> /root/PLUGIN_INFO
