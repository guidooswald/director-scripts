#!/usr/bin/env bash
#
# (c) Copyright 2018 Cloudera, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if [[ -z $CM_GPG_KEY_URL ]]; then
  TEMP_REPO_URL="${CM_REPOSITORY_URL%/}" # strip trailing slash if present
  if [[ $TEMP_REPO_URL =~ ^https?://archive.cloudera.com/cm6 ]]; then
    CM_GPG_KEY_URL="${TEMP_REPO_URL}/RPM-GPG-KEY-cloudera"
  elif [[ $TEMP_REPO_URL =~ ^https?://archive.cloudera.com/cm5 ]]; then
    CM_GPG_KEY_URL="${TEMP_REPO_URL%/*}/RPM-GPG-KEY-cloudera"
  else
    echo "URL for RPM GPG key cannot be determined from CM repository URL ${CM_REPOSITORY_URL}."
    echo "Please specify the URL for the key in the CM_GPG_KEY_URL variable."
  fi
fi
PREBAKED_DIRECTORY=/opt/cloudera/director
PREBAKED_GPG_KEY=${PREBAKED_DIRECTORY}/rhel-key

# Some images will have outdated cache information which can cause package installs to fail.
# The following will clean the cached data and the next install will fetch fresh repo info.
sudo rm -fr /var/cache/yum/*
sudo yum clean all

# Install ntp, curl, nscd, screen, python, bc, and rng-tools
sudo yum -y install ntp curl nscd screen python bc rng-tools

# Director can avoid downloading the GPG key for the Cloudera repository by using a prebaked key file
sudo mkdir -p "${PREBAKED_DIRECTORY}"
echo "Installing RPM GPG key from ${CM_GPG_KEY_URL} to ${PREBAKED_GPG_KEY}"
sudo curl -L "${CM_GPG_KEY_URL}" -o "${PREBAKED_GPG_KEY}"

# Configure the Cloudera Manager repository
echo "Configuring Cloudera Manager repository at $CM_REPOSITORY_URL"
sudo tee /etc/yum.repos.d/cloudera-manager.repo > /dev/null <<REPO
[cloudera-manager]
name=Cloudera Manager
baseurl=${CM_REPOSITORY_URL}
gpgKey=${CM_GPG_KEY_URL}
gpgcheck=1
REPO
sudo rpm --import "${PREBAKED_GPG_KEY}"

# Configure the JDK repository if necessary
# Not supporting signature checks at this time
if [[ "$JDK_REPOSITORY_URL" != "$CM_REPOSITORY_URL" ]]; then
  echo "Configuring JDK repository at $JDK_REPOSITORY_URL"
  sudo tee /etc/yum.repos.d/jdk.repo > /dev/null <<REPO
[jdk]
name=JDK
baseurl=${JDK_REPOSITORY_URL}
gpgcheck=0
REPO
fi

# Determine the name of the JDK package
case $JAVA_VERSION in
  1\.8)
    # Package name for RPM available from Cloudera Altus Director repo
    director_ver=$(basename "${JDK_REPOSITORY_URL}")
    if [[ $(echo "$director_ver >= 2.4" | bc) -eq 1 ]]; then
      JDK_PACKAGE="oracle-j2sdk${JAVA_VERSION}"
    else
      JDK_PACKAGE="jdk1.8.0_60"
    fi
    ;;
  *)
    # Package name for RPM available from Cloudera Manager or Cloudera Altus Director repo
    JDK_PACKAGE="oracle-j2sdk${JAVA_VERSION}"
    ;;
esac

echo "Installing JDK"
sudo yum -y install "$JDK_PACKAGE"
JAVA_HOME=$(ls -d /usr/java/*)
sudo alternatives --install /usr/bin/java java "${JAVA_HOME}/bin/java" 1
sudo alternatives --install /usr/bin/javac javac "${JAVA_HOME}/bin/javac" 1
sudo  ln -s "${JAVA_HOME}" /usr/java/default

echo "Installing CM Packages"
sudo yum -y install cloudera-manager-agent cloudera-manager-daemons cloudera-manager-server cloudera-manager-server-db-2

# Define service_control
. /tmp/service_control.sh

# Cloudera Manager needs ntp (either via ntpd or chronyd) to work properly
echo "Enabling ntpd / chronyd and nscd"
if hash chronyc 2>/dev/null; then
  service_control chronyd enable
else
  service_control ntpd enable
fi
service_control nscd enable

if [ -f /etc/selinux/config ]; then
  # Disable SELinux, as it doesn't play nicely with Cloudera Manager
  echo "Disabling SELinux"
  sudo sed -e 's/^SELINUX=enforcing/SELINUX=disabled/' -i /etc/selinux/config
  sudo sed -e 's/^SELINUX=permissive/SELINUX=disabled/' -i /etc/selinux/config
  sudo setenforce 0
fi

# Make sure iptables / firewalld is disabled so that we can properly access Cloudera Manager
echo "Disabling iptables / firewalld"
service_control iptables disable
if hash firewall-cmd 2>/dev/null; then
  service_control firewalld stop
fi

# Disable the automatic starting of Cloudera Manager. Director will handle this.
echo "Disabling Cloudera Manager"
service_control cloudera-scm-agent disable
service_control cloudera-scm-server disable
service_control cloudera-scm-server-db disable

exit 0
