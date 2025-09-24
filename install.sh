#!/usr/bin/env bash

#############
# VARIABLES #
#############

DISK=$1
UEFI=true
PART_TYPE='gpt'
HOSTNAME='arch'
MAIN_USER='epalanque'
INSTALL_TYPE=full
PACMAN_PARALLEL=100
CLEARROOT=false
MOUNTPOINT="/mnt/install"
HERE="$(dirname "$(readlink -f "$0")")"
DISKPART="${DISK}"

# Usage
if [[ -z "${DISK}" ]]; then
  echo
  echo "Usage:"
  echo "  ./system-install.sh [disk]"
  echo
  echo "Example: ./system-install.sh /dev/nvmen0"
  echo
  exit 0
fi

# Check if disk is proper
if ! $(lsblk ${DISK} | grep disk &>/dev/null); then
  echo "Provided device path is not proper, make sure the device is valid, exiting."
  exit 1
fi

if [[ ${DISK} =~ ^/dev/nvme.* ]]; then DISKPART="${DISK}p"; fi

# Check if UEFI supported
efivar -l &>/dev/null
if [[ $? != 0 ]]; then
  UEFI=false
  PART_TYPE='msdos'
fi

# Determine disk metadata
DISK_SERIAL=$(lsblk ${DISK} -o SERIAL | head -n 2)
DISK_UUID=$(echo ${DISK_SERIAL:(-4)})
DISK_SIZE_MB=$(( $(lsblk -b ${DISK} | grep disk | awk '{print $4}') / 1024 / 1024 ))

# Fixed sizes
fSWAP=81920  # 8 Go
fROOT=81920  # 80 Go
fVAR=40960   # 40 Go

# Percentage sizes
pSWAP=$(( $DISK_SIZE_MB / 20 ))  # 5%
pROOT=$(( $DISK_SIZE_MB / 2 ))   # 50%
pVAR=$(( $DISK_SIZE_MB / 5 ))    # 20%

# Decide if using fixed or percentage
[[ $fSWAP -gt $pSWAP ]] && SWAP=$pSWAP || SWAP=$fSWAP
[[ $fROOT -gt $pROOT ]] && ROOT=$pROOT || ROOT=$fSWAP
[[ $fVAR -gt $pVAR ]] && VAR=$pVAR || VAR=$fVAR
BOOT=512     ## 1 :: BOOT :: 512 Mo
HOME=100%    ## 5 :: HOME :: the rest


##########
# INPUTS #
##########

read -p "Quick install (without Git)? (y/n) " quick_install
if [[ "${quick_install}" == "y" ]]; then
  INSTALL_TYPE=quick
fi

read -p "Install desktop? (y/n) " desktop_install
if [[ "${desktop_install}" == "y" ]]; then
  echo -e "Choices:\n  - plasma\n  - gnome\n  - hyprland\n  - others (only with full setup)"
  read -p "Which one? " desktop
  if [[ ${desktop} =~ (^plasma.*|^gnome$|^cinnamon$|^hyprland$|^i3$) ]]; then
    true
  else
    echo "Invalid desktop, exiting."
    exit 1
  fi
fi

if [[ "${INSTALL_TYPE}" == "full" ]]; then
  echo
  mkdir -p /root/.ssh
  read -p "SSH key local or remote? " key_location
  if [[ "${key_location}" == "local" ]]; then
    read -p "Location (/path/to/key): " ssh_key_path
    cp "${ssh_key_path}" /root/.ssh/
  else
    read -p "Location (user@ip:path): " remote_location
    scp -o StrictHostKeychecking=no ${remote_location} /root/.ssh/
  fi
  chmod 600 /root/.ssh/id_*
fi

echo
echo "Enter your credentials..."
read -p "Username (default: ${MAIN_USER}): " username
[[ "${username}" != "" ]] && MAIN_USER="${username}"
read -p "Password: " -s password


##############
# VALIDATION #
##############

echo; echo
echo -e "# This script is about to format the following disk: #"
echo
echo -e "######    "${DISK}"    ######"
echo
echo -e "Partition table:"
echo -e "  - boot: $BOOT Mb"
echo -e "  - root: $ROOT Mb"
echo -e "  - var: $VAR Mb"
echo -e "  - swap: $SWAP Mb"
echo -e "  - home: $HOME (everything available)"
echo
read -p "Do you want to continue? (YES / NO) " ans

if [[ $ans != 'YES' ]]; then exit 0; fi


################
# PARTITIONING #
################

echo
echo -e "** PARTITIONNING DISK **"

# Init / Cleanup
clear
mkdir -p ${MOUNTPOINT}
echo -e "** CLEANING **"
umount ${DISK} &>/dev/null
umount -R ${MOUNTPOINT} &>/dev/null
if [[ -n $(pvdisplay | grep ${DISK}) ]]; then
  cryptsetup luksClose "${DISK_UUID}-var"
  cryptsetup luksClose "${DISK_UUID}-home"
  cryptsetup luksClose "${DISK_UUID}-root"
  vgremove "${DISK_UUID}_${HOSTNAME}" ${DISKPART}2 -y
  pvremove ${DISKPART}2
fi

# Create the partition
parted --script ${DISK} \
  mklabel ${PART_TYPE} \
  mkpart primary 1M ${BOOT}M \
  mkpart primary ext4 ${BOOT}M 100% \
  set 1 boot on || exit 1

# Creating boot part
echo
echo -e "** CREATING BOOT PARTITION **"
dd if=/dev/zero of=${DISKPART}1 bs=1M &>/dev/null
if ${UEFI}; then
  mkfs.fat -I -F32 ${DISKPART}1 || exit 1
else
  mkfs.ext4 ${DISKPART}1 || exit 1
fi

# Creating LVM pool
echo
echo -e "** CREATING LVM POOL **"
pvcreate -yff ${DISKPART}2 || exit 1
vgcreate -yff "${DISK_UUID}_${HOSTNAME}" ${DISKPART}2 || exit 1
lvcreate -y -L ${SWAP}M -n swap "${DISK_UUID}_${HOSTNAME}" ${DISKPART}2 || exit 1
lvcreate -v -y -L ${ROOT}M -n root "${DISK_UUID}_${HOSTNAME}" ${DISKPART}2 || exit 1
lvcreate -y -L ${VAR}M -n var "${DISK_UUID}_${HOSTNAME}" ${DISKPART}2 || exit 1
lvcreate -y -l ${HOME}FREE -n home "${DISK_UUID}_${HOSTNAME}" ${DISKPART}2 || exit 1


##############
# ENCRYPTION #
##############

# Encrypting home part
echo
echo -e "** CREATING HOME & VAR KEYS **"
mkdir -m 700 -p luks-keys
openssl genpkey -algorithm ED25519 > luks-keys/home
openssl genpkey -algorithm ED25519 > luks-keys/var

echo
echo -e "** ENCRYPTING ROOT **"
# Encrypt root
${CLEARROOT} || cryptsetup luksFormat -c serpent-xts-plain64 -s 512 "/dev/mapper/${DISK_UUID}_${HOSTNAME}-root"

echo
echo -e "** UNLOCKING ROOT **"
${CLEARROOT} || cryptsetup open "/dev/mapper/${DISK_UUID}_${HOSTNAME}-root" "${DISK_UUID}-root"
if [ $? != 0 ]; then exit 0; fi

echo
echo -e "** ENCRYPTING THE REST **"
# Encrypt /var
_var=true
while $_var; do
  echo -e "YES\n" | cryptsetup luksFormat -c serpent-xts-plain64 -s 512 "/dev/mapper/${DISK_UUID}_${HOSTNAME}-var" "luks-keys/var" && \
    cryptsetup -d luks-keys/var open "/dev/mapper/${DISK_UUID}_${HOSTNAME}-var" "${DISK_UUID}-var" && \
      _var=false
done

# Encrypt /home
_home=true
while $_home; do
  echo -e "YES\n" | cryptsetup luksFormat -c serpent-xts-plain64 -s 512 "/dev/mapper/${DISK_UUID}_${HOSTNAME}-home" "luks-keys/home" && \
    cryptsetup -d luks-keys/home open "/dev/mapper/${DISK_UUID}_${HOSTNAME}-home" "${DISK_UUID}-home" && \
      _home=false
done


#############
# FORMATING #
#############

# Format devices
echo
echo -e "** FORMATING PARTITIONS **"
${CLEARROOT} && mkfs.ext4 "/dev/mapper/${DISK_UUID}_${HOSTNAME}-root" || mkfs.ext4 "/dev/mapper/${DISK_UUID}-root"
mkfs.ext4 "/dev/mapper/${DISK_UUID}-var"
mkfs.ext4 "/dev/mapper/${DISK_UUID}-home"

# Mount the filesystem under /mnt
echo
echo -e "** MOUNTING PARTITIONS **"
${CLEARROOT} && mount "/dev/mapper/${DISK_UUID}_${HOSTNAME}-root" "${MOUNTPOINT}" || mount "/dev/mapper/${DISK_UUID}-root" "${MOUNTPOINT}"
mkdir -p ${MOUNTPOINT}/{etc,boot,home,var}
mount ${DISKPART}1 "${MOUNTPOINT}/boot"
mount "/dev/mapper/${DISK_UUID}-var" "${MOUNTPOINT}/var"
mount "/dev/mapper/${DISK_UUID}-home" "${MOUNTPOINT}/home"

# Setup LUKS configs
mv luks-keys "${MOUNTPOINT}/etc/"
cat > "${MOUNTPOINT}/etc/crypttab" <<EOF
swap /dev/mapper/${DISK_UUID}_${HOSTNAME}-swap    /dev/urandom swap,cipher=serpent-xts-plain64,size=512
var  /dev/mapper/${DISK_UUID}_${HOSTNAME}-var     /etc/luks-keys/var
home /dev/mapper/${DISK_UUID}_${HOSTNAME}-home    /etc/luks-keys/home
EOF


#############
# BOOTSTRAP #
#############

# Repo updates
pacman -Syy

# Installing base system
timedatectl set-ntp true
sed -i "s|^#ParallelDownloads.*|ParallelDownloads = ${PACMAN_PARALLEL}|g" /etc/pacman.conf
pacman -S --noconfirm --needed reflector
mkdir -p "${MOUNTPOINT}/etc/pacman.d" "/etc/pacman.d"
echo
echo -n "Determining 5 fastest mirrors in Canada... "
reflector --fastest 5 --country Canada --sort rate --save /etc/pacman.d/mirrorlist.new &>/dev/null
echo "done!"
cp /etc/pacman.d/mirrorlist.new "${MOUNTPOINT}/etc/pacman.d/mirrorlist"
mv /etc/pacman.d/mirrorlist.new /etc/pacman.d/mirrorlist

pacstrap ${MOUNTPOINT} base base-devel
genfstab -U ${MOUNTPOINT} >> "${MOUNTPOINT}/etc/fstab"

# Configure swap
cat >> "${MOUNTPOINT}/etc/fstab" <<EOF
/dev/mapper/swap      none      swap      defaults      0 0
EOF

# Install ssh keys
if [[ "${INSTALL_TYPE}" == "full" ]]; then
  mkdir -p "${MOUNTPOINT}/root/.ssh"
  cp /root/.ssh/id_* "${MOUNTPOINT}/root/.ssh/"
fi


#####################
# POST-INSTALLATION #
#####################

# Pushing configuration script
cat >"${MOUNTPOINT}/opt/install-after-chroot.sh" <<EOF

# Install background user
useradd -mUr -d /opt/bottyboop bottyboop &>/dev/null
echo 'bottyboop ALL=(ALL) NOPASSWD: ALL' >>/etc/sudoers

# Activate additionnal repositories #
if [[ -f /etc/pacman.conf.ori ]]; then
  cp /etc/pacman.conf /etc/pacman.conf.ori
fi
sed -i '/^SigLevel    = /c\SigLevel =    Never' /etc/pacman.conf
sed -i 's|^#Color|Color|g' /etc/pacman.conf
sed -i 's|^#TotalDownload|TotalDownload|g' /etc/pacman.conf
sed -i 's|^#ParallelDownloads.*|ParallelDownloads = 20|g' /etc/pacman.conf
if ! $(grep -Fx [multilib] /etc/pacman.conf &>/dev/null); then
  cp "/etc/pacman.conf" "/tmp/pacman.conf"
  echo '[multilib]' | tee --append "/tmp/pacman.conf" &>/dev/null
  echo 'Include = /etc/pacman.d/mirrorlist' | tee --append "/tmp/pacman.conf" &>/dev/null
  cp "/tmp/pacman.conf" "/etc/pacman.conf"
fi

# Install yay & dependencies #
pacman -Sd git yajl wget diffutils gettext go --noconfirm --needed
wget -q https://aur.archlinux.org/cgit/aur.git/snapshot/yay.tar.gz -O /tmp/yay.tar.gz
tar -xvf /tmp/yay.tar.gz -C /tmp/
cd /tmp/yay
chown -R bottyboop: .
sudo -u bottyboop makepkg
pacman -U --noconfirm yay-*pkg.tar.*
cd
rm -rf /tmp/yay*

# Configure users
useradd -mU ${MAIN_USER} &>/dev/null
echo '${MAIN_USER} ALL=(ALL) NOPASSWD: ALL' >>/etc/sudoers
passwd ${MAIN_USER} --stdin <<< ${password}

# Enable parallel download
sed -i "s|^#ParallelDownloads.*|ParallelDownloads = ${PACMAN_PARALLEL}|g" /etc/pacman.conf

# Extra pkg install
pacman -S --noconfirm --needed \
  grub \
  os-prober \
  efivar \
  ntp \
  efitools \
  efibootmgr \
  screen \
  terminator \
  tmux \
  gptfdisk \
  vim \
  git \
  openssh \
  rsync \
  linux \
  linux-headers \
  linux-firmware \
  apparmor \
  lvm2 \
  dhclient \
  yajl \
  wget \
  curl \
  diffutils \
  gettext \
  go

# Base desktop install
if [[ "${desktop_install}" == "y" ]]; then
  case "${desktop}" in
    "plasma")
      sudo -u bottyboop yay -S --noconfirm --needed \
        plasma \
        kde-applications \
        sddm \
        sddm-catppuccin-git && \
          systemctl enable sddm
      ;;

    "gnome")
      sudo -u bottyboop yay -S --noconfirm --needed gnome gnome-extra gdm && \
        systemctl enable gdm
      ;;

    "hyprland")
      sudo -u bottyboop yay -S --noconfirm --needed \
        hyprland \
        hyprpaper \
        hypridle \
        hyprlock \
        hyprsysteminfo \
        hyprsunset \
        hyprland-qt-support \
        hyprpolkitagent \
        hyprshot \
        hyprcursor \
        rose-pine-hyprcursor \
        waybar \
        network-manager-applet \
        xdg-desktop-portal-hyprland \
        brightnessctl \
        mako \
        uwsm \
        ngw-look \
        sddm \
        where-is-my-sddm-theme-git && \
          sed -i 's/Current=.*/Current=where_is_my_sddm_theme/' /etc/sddm.conf.d/theme.conf && \
            systemctl enable sddm
      ;;
  esac
fi

# Cleanup
pacman -Rc kmix --noconfirm

# Locale config
systemctl enable ntpd
ln -s /usr/share/zoneinfo/America/Toronto /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen
echo LANG=en_US.UTF-8 > /etc/locale.conf
echo "${HOSTNAME}" >/etc/hostname
echo "127.0.0.1     ${HOSTNAME}" >/etc/hosts
locale-gen

# Adding LUKS stuff; ORDER IS IMPORTANT
if ${CLEARROOT}; then
  sed -i 's/HOOKS=(.*/HOOKS=(base udev autodetect modconf keyboard keymap block lvm2 resume filesystems fsck)/g' /etc/mkinitcpio.conf
else
  sed -i 's/HOOKS=(.*/HOOKS=(base udev autodetect modconf keyboard keymap block encrypt lvm2 resume filesystems fsck)/g' /etc/mkinitcpio.conf
fi

# Modprobe blacklist
echo "blacklist pcspkr" >/etc/modprobe.d/nobeep.conf

# System Init Generation
mkinitcpio -P

# Enable apparmor policies
systemctl enable apparmor.service

# Configuring bootloader
if ${UEFI}; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
else
  grub-install --target=i386-pc ${DISK}
fi
${CLEARROOT} || sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="cryptdevice=\/dev\/mapper\/${DISK_UUID}_${HOSTNAME}-root:${DISK_UUID}-root"/g' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash apparmor=1 security=apparmor"/g' /etc/default/grub
sed -i 's/#GRUB_ENABLE_CRYPTODISK=/GRUB_ENABLE_CRYPTODISK=/g' /etc/default/grub
sed -i 's/#GRUB_DISABLE_OS_PROBER=/GRUB_DISABLE_OS_PROBER=/g' /etc/default/grub
os-prober
grub-mkconfig -o /boot/grub/grub.cfg

if [[ "${INSTALL_TYPE}" == "full" ]]; then
  if [[ -d /opt/linux-setup ]]; then
    cd /opt/linux-setup
    git stash
    git pull
  else
    cd /opt/
    GIT_SSH_COMMAND="ssh -o StrictHostKeychecking=no" git clone git@github.com:Goggot/linux-setup.git
  fi

  cd

  if [ -d '/opt/linux-setup' ]; then
    chown bottyboop -R /opt/linux-setup
    chmod -R 755 /opt/linux-setup
    chmod -R a+x /opt/linux-setup
  fi

  # Install configuration
  echo "desktop-${desktop}" > "/tmp/systype"
  /opt/linux-setup/scripts/restore.bash
fi
EOF

# Configuration
chmod a+x "${MOUNTPOINT}/opt/install-after-chroot.sh"
arch-chroot "${MOUNTPOINT}" "/opt/install-after-chroot.sh"


###########
# CLEANUP #
###########

# Cleanup
sync
umount -R "${MOUNTPOINT}"
echo
echo -e "Installation finished, you can now reboot!"
echo
