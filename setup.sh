#!/usr/bin/env sh

# This script sets up dockerized Redash on Debian 12.x, Fedora 38 or later, Ubuntu LTS 20.04 & 22.04,
# RHEL (and compatible) 8.x & 9.x, and Amazon Linux 2 / 2023
set -eu

REDASH_BASE_PATH=/opt/redash
DONT_START=no
OVERWRITE=no
PREVIEW=no
REDASH_VERSION=""
COMPOSE_WRAPPER_DEFINED=no

# Pinned Docker Compose v2 version used when we have to install the CLI plugin
# manually (Amazon Linux 2). Bump deliberately; verify the SHA256 from the
# release page when you do.
COMPOSE_PLUGIN_VERSION="v2.29.7"

# Ensure the script is being run as root
ID=$(id -u)
if [ "0$ID" -ne 0 ]; then
	echo "Please run this script as root"
	exit
fi

# Ensure the 'docker' and 'docker-compose' commands are available
# and if not, ensure the script can install them
# Also detect which Docker Compose command to use and create wrapper function
SKIP_DOCKER_INSTALL=no

# Detect and define docker_compose wrapper function at global scope
detect_and_define_compose() {
	if [ "$COMPOSE_WRAPPER_DEFINED" = "yes" ]; then
		return 0
	fi

	if docker compose version >/dev/null 2>&1; then
		docker_compose() { docker compose "$@"; }
		COMPOSE_WRAPPER_DEFINED=yes
	elif command -v docker-compose >/dev/null 2>&1; then
		docker_compose() { docker-compose "$@"; }
		COMPOSE_WRAPPER_DEFINED=yes
	else
		echo "Error: Neither 'docker compose' nor 'docker-compose' found." >&2
		return 1
	fi
}

if command -v docker >/dev/null 2>&1; then
	# Docker is already installed, detect which compose command to use
	if detect_and_define_compose; then
		SKIP_DOCKER_INSTALL=yes
	fi
	# If Compose not found, continue to install docker-compose-plugin
elif [ ! -f /etc/os-release ]; then
	echo "Unknown Linux distribution.  This script presently works only on Debian, Fedora, Ubuntu, RHEL (and compatible), and Amazon Linux"
	exit 1
fi

# Parse any user provided parameters
opts="$(getopt -o doph -l dont-start,overwrite,preview,help,version: --name "$0" -- "$@")"
eval set -- "$opts"

while true; do
	case "$1" in
	-d | --dont-start)
		DONT_START=yes
		shift
		;;
	-o | --overwrite)
		OVERWRITE=yes
		shift
		;;
	-p | --preview)
		PREVIEW=yes
		shift
		;;
	--version)
		REDASH_VERSION="$2"
		shift 2
		;;
	-h | --help)
		echo "Redash setup script usage: $0 [-d|--dont-start] [-p|--preview] [-o|--overwrite] [--version <tag>]"
		echo "  The --preview (also -p) option uses the Redash 'preview' Docker image instead of the last stable release"
		echo "  The --version option installs the specified version tag of Redash (e.g., 10.1.0)"
		echo "  The --overwrite (also -o) option replaces any existing configuration with a fresh new install"
		echo "  The --dont-start (also -d) option installs Redash, but doesn't automatically start it afterwards"
		exit 1
		;;
	--)
		shift
		break
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
done

install_docker_debian() {
	echo "** Installing Docker (Debian) **"

	export DEBIAN_FRONTEND=noninteractive
	apt-get -qqy update
	DEBIAN_FRONTEND=noninteractive apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
	apt-get -yy install apt-transport-https ca-certificates curl pwgen gnupg

	# Add Docker GPG signing key
	if [ ! -f "/etc/apt/keyrings/docker.gpg" ]; then
		install -m 0755 -d /etc/apt/keyrings
		curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
		chmod a+r /etc/apt/keyrings/docker.gpg
	fi

	# Add Docker download repository to apt
	cat <<EOF >/etc/apt/sources.list.d/docker.list
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF
	apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_fedora() {
	echo "** Installing Docker (Fedora) **"

	# Add Docker package repository
	dnf -qy install dnf-plugins-core
	dnf config-manager --quiet --add-repo https://download.docker.com/linux/fedora/docker-ce.repo

	# Install Docker
	dnf install -qy docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin pwgen

	# Start Docker and enable it for automatic start at boot
	systemctl start docker && systemctl enable docker
}

install_docker_amazon_linux_2() {
	echo "** Installing Docker (Amazon Linux 2) **"

	# AL2 ships Docker via amazon-linux-extras, NOT via Docker's upstream repos.
	# The upstream docker-ce CentOS/RHEL repo does not provide AL2-compatible
	# packages, so we use Amazon's curated topic instead.

	# Enable EPEL for pwgen (not in the default AL2 repos)
	amazon-linux-extras install -y epel

	# Enable the docker topic and install
	amazon-linux-extras enable docker
	yum clean metadata
	yum install -y docker pwgen

	# AL2's docker package does NOT bundle the Compose v2 plugin, and there is
	# no official AL2 docker-compose-plugin RPM. Install the static binary as a
	# CLI plugin so `docker compose ...` works the same as on every other distro.
	#
	# SECURITY NOTE: this downloads a release binary over HTTPS without
	# verifying a checksum. If you care (you should), pin a known-good SHA256
	# below and uncomment the verification block. Checksums are published at
	# https://github.com/docker/compose/releases
	ARCH_RAW=$(uname -m)
	case "$ARCH_RAW" in
		x86_64)  COMPOSE_ARCH="x86_64" ;;
		aarch64) COMPOSE_ARCH="aarch64" ;;
		*)
			echo "Unsupported architecture for Compose plugin install: $ARCH_RAW" >&2
			exit 1
			;;
	esac

	# /usr/libexec/docker/cli-plugins is the system-wide plugin path that the
	# AL2 docker package's CLI searches. Using /usr/local/lib/docker/cli-plugins
	# also works on most distros but is NOT picked up by AL2's docker build.
	PLUGIN_DIR=/usr/libexec/docker/cli-plugins
	mkdir -p "$PLUGIN_DIR"
	curl -fsSL \
		"https://github.com/docker/compose/releases/download/${COMPOSE_PLUGIN_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
		-o "$PLUGIN_DIR/docker-compose"
	chmod 0755 "$PLUGIN_DIR/docker-compose"

	# Optional integrity check — fill in the expected SHA256 for your pinned
	# version + arch and uncomment to enforce.
	#
	# EXPECTED_SHA256="<paste sha256 here>"
	# echo "${EXPECTED_SHA256}  ${PLUGIN_DIR}/docker-compose" | sha256sum -c -

	# Start Docker and enable it for automatic start at boot
	systemctl start docker && systemctl enable docker
}

install_docker_rhel() {
	echo "** Installing Docker (RHEL and compatible) **"

	# Add EPEL package repository
	if [ "x$DISTRO" = "xrhel" ]; then
		# Genuine RHEL doesn't have the epel-release package in its repos
		RHEL_VER=$(. /etc/os-release && echo "$VERSION_ID" | cut -d "." -f1)
		if [ "0$RHEL_VER" -eq "9" ]; then
			yum install -qy https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
		else
			yum install -qy https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
		fi
		yum install -qy yum-utils
	else
		# RHEL compatible distros do have epel-release available
		yum install -qy epel-release yum-utils
	fi
	yum update -qy

	# Add Docker package repository
	yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
	yum update -qy

	# Install Docker
	yum install -qy docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin pwgen

	# Start Docker and enable it for automatic start at boot
	systemctl start docker && systemctl enable docker
}

install_docker_ubuntu() {
	echo "** Installing Docker (Ubuntu) **"

	export DEBIAN_FRONTEND=noninteractive
	apt-get -qqy update
	DEBIAN_FRONTEND=noninteractive sudo -E apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
	apt-get -yy install apt-transport-https ca-certificates curl pwgen gnupg

	# Add Docker GPG signing key
	if [ ! -f "/etc/apt/keyrings/docker.gpg" ]; then
		install -m 0755 -d /etc/apt/keyrings
		curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
		chmod a+r /etc/apt/keyrings/docker.gpg
	fi

	# Add Docker download repository to apt
	cat <<EOF >/etc/apt/sources.list.d/docker.list
deb [arch=""$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF
	apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

create_directories() {
	echo "** Creating $REDASH_BASE_PATH directory structure for Redash **"

	if [ ! -e "$REDASH_BASE_PATH" ]; then
		mkdir -p "$REDASH_BASE_PATH"
		chown "$USER:" "$REDASH_BASE_PATH"
	fi

	if [ -e "$REDASH_BASE_PATH"/postgres-data ]; then
		# PostgreSQL database directory seems to exist already

		if [ "x$OVERWRITE" = "xyes" ]; then
			# We've been asked to overwrite the existing database
			echo "Shutting down any running Redash instance"
			if [ -e "$REDASH_BASE_PATH"/compose.yaml ]; then
				docker_compose -f "$REDASH_BASE_PATH"/compose.yaml down
			fi

			echo "Moving old Redash PG database directory out of the way"
			mv "${REDASH_BASE_PATH}/postgres-data" "${REDASH_BASE_PATH}/postgres-data-${TIMESTAMP_NOW}"
			mkdir "$REDASH_BASE_PATH"/postgres-data
		fi
	else
		mkdir "$REDASH_BASE_PATH"/postgres-data
	fi
}

create_env() {
	echo "** Creating Redash environment file **"

	# Minimum mandatory values (when not just developing)
	COOKIE_SECRET=$(pwgen -1s 32)
	SECRET_KEY=$(pwgen -1s 32)
	PG_PASSWORD=$(pwgen -1s 32)
	DATABASE_URL="postgresql://postgres:${PG_PASSWORD}@postgres/postgres"

	if [ -e "$REDASH_BASE_PATH"/env ]; then
		# There's already an environment file

		if [ "x$OVERWRITE" = "xno" ]; then
			echo
			echo "Environment file already exists, reusing that one + and adding any missing (mandatory) values"

			# Add any missing mandatory values
			REDASH_COOKIE_SECRET=
			REDASH_COOKIE_SECRET=$(. "$REDASH_BASE_PATH"/env && echo "$REDASH_COOKIE_SECRET")
			if [ -z "$REDASH_COOKIE_SECRET" ]; then
				echo "REDASH_COOKIE_SECRET=$COOKIE_SECRET" >>"$REDASH_BASE_PATH"/env
				echo "REDASH_COOKIE_SECRET added to env file"
			fi

			REDASH_SECRET_KEY=
			REDASH_SECRET_KEY=$(. "$REDASH_BASE_PATH"/env && echo "$REDASH_SECRET_KEY")
			if [ -z "$REDASH_SECRET_KEY" ]; then
				echo "REDASH_SECRET_KEY=$SECRET_KEY" >>"$REDASH_BASE_PATH"/env
				echo "REDASH_SECRET_KEY added to env file"
			fi

			POSTGRES_PASSWORD=
			POSTGRES_PASSWORD=$(. "$REDASH_BASE_PATH"/env && echo "$POSTGRES_PASSWORD")
			if [ -z "$POSTGRES_PASSWORD" ]; then
				POSTGRES_PASSWORD=$PG_PASSWORD
				echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" >>"$REDASH_BASE_PATH"/env
				echo "POSTGRES_PASSWORD added to env file"
			fi

			REDASH_DATABASE_URL=
			REDASH_DATABASE_URL=$(. "$REDASH_BASE_PATH"/env && echo "$REDASH_DATABASE_URL")
			if [ -z "$REDASH_DATABASE_URL" ]; then
				echo "REDASH_DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@postgres/postgres" >>"$REDASH_BASE_PATH"/env
				echo "REDASH_DATABASE_URL added to env file"
			fi

			echo
			return
		fi

		# Move any existing environment file out of the way
		mv -f "${REDASH_BASE_PATH}/env" "${REDASH_BASE_PATH}/env.old-${TIMESTAMP_NOW}"
	fi

	echo "Generating brand new environment file"

	cat <<EOF >"$REDASH_BASE_PATH"/env
PYTHONUNBUFFERED=0
REDASH_LOG_LEVEL=INFO
REDASH_REDIS_URL=redis://redis:6379/0
REDASH_COOKIE_SECRET=$COOKIE_SECRET
REDASH_SECRET_KEY=$SECRET_KEY
POSTGRES_PASSWORD=$PG_PASSWORD
REDASH_DATABASE_URL=$DATABASE_URL
REDASH_ENFORCE_CSRF=true
REDASH_GUNICORN_TIMEOUT=60
EOF
}

setup_compose() {
	echo "** Creating Redash Docker compose file **"

	cd "$REDASH_BASE_PATH"
	GIT_BRANCH="${REDASH_BRANCH:-master}" # Default branch/version to master if not specified in REDASH_BRANCH env var
	if [ "x$OVERWRITE" = "xyes" -a -e compose.yaml ]; then
		mv -f compose.yaml compose.yaml.old-${TIMESTAMP_NOW}
	fi
	curl -fsSOL https://raw.githubusercontent.com/getredash/setup/"$GIT_BRANCH"/data/compose.yaml

	# Check for conflicts between --version and --preview options
	if [ "x$PREVIEW" = "xyes" ] && [ -n "$REDASH_VERSION" ]; then
		echo "Error: Cannot specify both --preview and --version options"
		exit 1
	fi

	# Set TAG based on provided options
	if [ "x$PREVIEW" = "xyes" ]; then
		TAG="preview"
		echo "** Using preview version of Redash **"
	elif [ -n "$REDASH_VERSION" ]; then
		TAG="$REDASH_VERSION"
		echo "** Using specified Redash version: $TAG **"
	else
		# Get the latest stable version from GitHub API
		echo "** Fetching latest stable Redash version **"
		LATEST_TAG=$(curl -s https://api.github.com/repos/getredash/redash/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
		if [ -n "$LATEST_TAG" ]; then
			# Remove 'v' prefix if present (GitHub tags use 'v', Docker tags don't)
			TAG=$(echo "$LATEST_TAG" | sed 's/^v//')
			echo "** Using latest stable Redash version: $TAG **"
		else
			# Fallback to hardcoded version if API call fails
			TAG="latest"
			echo "** Warning: Failed to fetch latest version, using fallback version: $TAG **"
		fi
	fi

	sed -i "s|__TAG__|$TAG|" compose.yaml
	export COMPOSE_FILE="$REDASH_BASE_PATH"/compose.yaml
	export COMPOSE_PROJECT_NAME=redash
}

create_make_default() {
	echo "** Creating redash_make_default.sh script **"

	curl -fsSOL https://raw.githubusercontent.com/getredash/setup/"$GIT_BRANCH"/redash_make_default.sh
	sed -i "s|__COMPOSE_FILE__|$COMPOSE_FILE|" redash_make_default.sh
	sed -i "s|__TARGET_FILE__|$PROFILE|" redash_make_default.sh
	chmod +x redash_make_default.sh
}

startup() {
	if [ "x$DONT_START" != "xyes" ]; then
		echo
		echo "*********************"
		echo "** Starting Redash **"
		echo "*********************"
		echo "** Initialising Redash database **"
		docker_compose run --rm server create_db

		echo "** Starting the rest of Redash **"
		docker_compose up -d

		echo
		echo "Redash has been installed and is ready for configuring at http://$(hostname -f):5000"
		echo
	else
		echo
		echo "*************************************************************"
		echo "** As requested, Redash has been installed but NOT started **"
		echo "*************************************************************"
		echo
	fi
}

echo
echo "Redash installation script. :)"
echo

TIMESTAMP_NOW=$(date +'%Y.%m.%d-%H.%M')

# Run the distro specific Docker installation
PROFILE=.profile
if [ "$SKIP_DOCKER_INSTALL" = "yes" ]; then
	echo "Docker and Docker Compose are already installed, so skipping that step."
else
	DISTRO=$(. /etc/os-release && echo "$ID")
	case "$DISTRO" in
	debian)
		install_docker_debian
		;;
	fedora)
		install_docker_fedora
		;;
	amzn)
		# Amazon Linux 2 and Amazon Linux 2023 are very different beasts:
		#   - AL2   uses amazon-linux-extras + an old kernel/glibc, no upstream
		#           docker-ce repo, no compose plugin RPM.
		#   - AL2023 is dnf-based and Fedora-ish; the Fedora installer works.
		AMZN_VER=$(. /etc/os-release && echo "$VERSION_ID")
		case "$AMZN_VER" in
		2)
			PROFILE=.bashrc
			install_docker_amazon_linux_2
			;;
		2023)
			install_docker_fedora
			;;
		*)
			echo "Unsupported Amazon Linux version: $AMZN_VER"
			exit 1
			;;
		esac
		;;
	ubuntu)
		install_docker_ubuntu
		;;
	almalinux | centos | ol | rhel | rocky)
		PROFILE=.bashrc
		install_docker_rhel
		;;
	*)
		echo "This doesn't seem to be a Debian, Fedora, Ubuntu, RHEL (compatible), nor Amazon Linux system, so this script doesn't know how to add Docker to it."
		echo
		echo "Please contact the Redash project via GitHub and ask about getting support added, or add it yourself and let us know. :)"
		echo
		exit
		;;
	esac
fi

# Detect the right Docker Compose command to use (after Docker installation if needed)
detect_and_define_compose
echo "Using compose command: $(docker_compose version | head -n1)"

# Ensure pwgen is available (needed for generating secrets)
if ! command -v pwgen >/dev/null 2>&1; then
	echo "** Installing pwgen **"
	if [ -f /etc/debian_version ]; then
		apt-get update -qq
		apt-get install -y pwgen
	elif [ -f /etc/redhat-release ] || [ -f /etc/system-release ]; then
		# /etc/system-release covers Amazon Linux, which lacks /etc/redhat-release
		if command -v dnf >/dev/null 2>&1; then
			dnf install -y pwgen
		elif command -v amazon-linux-extras >/dev/null 2>&1; then
			amazon-linux-extras install -y epel
			yum install -y pwgen
		else
			yum install -y pwgen
		fi
	else
		echo "Warning: pwgen not found and unable to install automatically on this system."
		echo "Please install pwgen manually: sudo apt-get install pwgen (Debian/Ubuntu) or sudo yum install pwgen (RHEL/CentOS)"
		exit 1
	fi
fi

# Do the things that aren't distro specific
create_directories
create_env
setup_compose
create_make_default
startup

echo "If you want Redash to be your default Docker Compose project when you login to this server"
echo "in future, then please run $REDASH_BASE_PATH/redash_make_default.sh"
echo
echo "That will set some Docker specific environment variables just for Redash.  If you"
echo "already use Docker Compose on this computer for other things, you should probably skip it."
