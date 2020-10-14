#!/bin/sh

WORKING_DIR="$(realpath "$(dirname "${0}")")"

. "${WORKING_DIR}/shell-utils/util.sh"

CONFIG_FILE="${WORKING_DIR}/install.config"

PACKAGES="vim
          ranger
          man-db
          man-pages
          texinfo
          wget
          networkmanager
          network-manager-applet
          ntp
          bluez
          bluez-utils
          notification-daemon
          gnome-keyring
          seahorse
          ttf-fira-code
          noto-fonts
          noto-fonts-cjk
          noto-fonts-emoji
          noto-fonts-extra
          rxvt-unicode
          pulseaudio
          pulseaudio-bluetooth
          alsa-utils
          pavucontrol
          pasystray
          grub
          efibootmgr
          os-prober
	  base-devel
          git
          zsh
          xorg-server
	  xorg-xinit
          i3-gaps
          i3lock
          i3status
          dmenu
          feh
          xss-lock
          openssl
          "

AUR_PACKAGES="google-chrome
              ly-git
             "
AUR_PKG_INSTALL_USER='aurpkginstalluser'
HOSTNAME_REGEX='^hostname[ \t]*=[ \t]*[[:alnum:]]+$'
ROOT_PASS_REGEX='^root_pass[ \t]*=[ \t]*.+$'
USER_REGEX='^user[ \t]*=[ \t]*[[:alnum:]]+:.+:[0|1]$'

################################################################################

setup_hostname() {
    local hname=$(grep -E "${HOSTNAME_REGEX}" "${CONFIG_FILE}" | sed 's/.*=[ \t]*//')
    echo "${hname}" > /etc/hostname
    echo '127.0.0.1 localhost' >/etc/hosts
    echo '::1 localhost' >>/etc/hosts
    echo "127.0.1.1 ${hname}.localdomain ${hname}" >>/etc/hosts
}

setup_root_password() {
    local pass=$(grep -E "${ROOT_PASS_REGEX}" "${CONFIG_FILE}" | sed 's/.*=[ \t]*//')
    usermod -p "$(openssl passwd -6 "${pass}")" root
}

setup_users() {
    local users=$(grep -E "${USER_REGEX}" "${CONFIG_FILE}" | sed 's/.*=[ \t]*//')
    for user in ${users}; do
        local username="$(echo ${user} | cut -d ':' -f1)"
        local password="$(echo ${user} | grep -o -E ':.*:' | sed 's/^:\(.*\):$/\1/')"
        local issudoer="$(echo ${user} | grep -o -E '[1|0]$')"
        useradd -m "${username}"
        usermod -p "$(openssl passwd -6 "${password}")" "${username}"
        if [ ${issudoer} -eq 1 ]; then
            echo 'Defaults targetpw' >"/etc/sudoers.d/${username}"
            echo "${username} ALL=(ALL) ALL" >>"/etc/sudoers.d/${username}"
        fi
        mkdir -p "/home/${username}/Pictures/wallpapers"
        chown -R "${username}":"${username}" "/home/${username}/Pictures"
        mkdir -p "/home/${username}/Work"
        chown -R "${username}":"${username}" "/home/${username}/Work"
        "${WORKING_DIR}/config/update_config.sh" --user "${username}"
    done
}

pre_install_aur_packages() {
    # I need a regular user that can elevate to root
    # through sudo so I can install AUR packages through
    # makepkg command
    useradd "${AUR_PKG_INSTALL_USER}"
    echo "${AUR_PKG_INSTALL_USER} ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/${AUR_PKG_INSTALL_USER}"
}

post_install_aur_packages() {
    userdel "${AUR_PKG_INSTALL_USER}"
    rm "/etc/sudoers.d/${AUR_PKG_INSTALL_USER}"
}

setup_timezone() {
    ln -sf /usr/share/zoneinfo/Europe/Bucharest /etc/localtime &&
        hwclock --systohc &&
        systemctl enable ntpd.service
}

setup_localization() {
    sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen &&
        locale-gen &&
        echo 'LANG=en_US.UTF-8' >/etc/locale.conf
}

install_package() {
    local package_name=$1
    pacman -S --noconfirm "${package_name}"
}

install_aur_package() {
    local aur_package_name="$1"
    git clone "https://aur.archlinux.org/${aur_package_name}.git" &&
        chown -R ${AUR_PKG_INSTALL_USER}:${AUR_PKG_INSTALL_USER} "./${aur_package_name}" &&
        cd "./${aur_package_name}" &&
        su ${AUR_PKG_INSTALL_USER} --command="makepkg -s --noconfirm" &&
        pacman -U --noconfirm *.pkg.tar.*
    local ret=$?
    cd "${WORKING_DIR}"
    return ${ret}
}

intel_integrated_graphics() {
    lspci -v | grep VGA | grep -i intel
}

nvidia_dedicated_graphics() {
    lspci -v | grep -e VGA -e 3D | grep -i nvidia
}

amd_dedicated_graphics() {
    lspci -v | grep -e VGA -e 3D | grep -i amd
}

install_amd_gpu_drivers() {
    perform_task_arg install_package xf86-video-amdgpu 'Installing amd driver for dedicated graphics ' &&
    perform_task_arg install_package mesa 'Installing package mesa ' &&
    perform_task_arg install_package libva-mesa-driver 'Installling libva-mesa-driver '
}

enable_ucode_updates() {
    if [ -n "$(lscpu | grep Vendor | grep -i intel)" ]; then
        install_package intel-ucode
    elif [ -n "$(lscpu | grep Vendor | grep -i amd)" ]; then
        install_package amd-ucode
    fi
}

install_grub_bootloader() {
    print_msg '--------------------------------\n'
    print_msg 'Installing grub boot-loader\n'
    print_msg '--------------------------------\n'
    grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB &&
        grub-mkconfig -o /boot/grub/grub.cfg >$(tty) 2>&1 &&
        print_msg '-------------SUCCESS------------\n' ||
        print_msg '-------------FAILED-------------\n'
}

enable_ly_display_manager() {
    systemctl disable getty@tty2.service
    systemctl enable ly.service
}

enable_network_manager() {
    systemctl enable NetworkManager.service
}

enable_bluetooth() {
    systemctl enable bluetooth.service
}

configure_gnome_keyring() {
    local last_auth_entry=$(grep --line-number -E "^auth" /etc/pam.d/login | tail -n 1 | sed 's/\([0-9]\+\):.*/\1/')
    sed -i "${last_auth_entry} s/^\(auth.*\)/&\nauth\toptional\tpam_gnome_keyring.so/" /etc/pam.d/login
    local last_session_entry=$(grep --line-number -E "^session" /etc/pam.d/login | tail -n 1 | sed 's/\([0-9]\+\):.*/\1/')
    sed -i "${last_session_entry} s/^\(session.*\)/&\nsession\toptional\tpam_gnome_keyring.so auto_start/" /etc/pam.d/login
}

###############################################################################

if [ -t 1 ]; then
    print_msg "ERR: Run ./install.sh instead. Check readme for more details on how to use the installer.\n"
    exit 1
fi

if [ ! -f "${CONFIG_FILE}" ]; then
    print_msg "ERR: Missing config file. Check readme for more details on how to use the installer.\n"
    exit 2
fi

for package in ${PACKAGES}; do
    perform_task_arg install_package ${package} "Installing package ${package} "
done

perform_task setup_hostname 'Setting up hostname'
perform_task setup_root_password 'Setting up root password'
perform_task setup_users 'Setting up users'

perform_task setup_timezone 'Setting up timezone '
perform_task setup_localization 'Setting up localization '

perform_task pre_install_aur_packages 'Setting up prerequisites to install AUR packages'
for package in ${AUR_PACKAGES}; do
    perform_task_arg install_aur_package ${package} "Installing AUR package ${package} "
done
perform_task post_install_aur_packages 'Tearing down prerequisites for AUR packages'

intel_integrated_graphics && perform_task_arg install_package xf86-video-intel "Installing intel driver for integrated graphics "
nvidia_dedicated_graphics && perform_task_arg install_package nvidia "Installing nvidia driver for dedicated graphics "
nvidia_dedicated_graphics && intel_integrated_graphics && perform_task_arg install_package nvidia-prime "Instaling nvidia prime (for optimus technology) "
amd_dedicated_graphics && install_amd_gpu_drivers


perform_task enable_ly_display_manager 'Enabling Ly display manager '
perform_task enable_network_manager 'Enabling Network Manager '
perform_task enable_bluetooth 'Enabling Bluetooth '
perform_task configure_gnome_keyring 'Enabling sensitive information encryption through gnome keyring '

perform_task enable_ucode_updates 'Enabling ucode updates '
install_grub_bootloader

check_for_errors
