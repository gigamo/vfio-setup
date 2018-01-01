#!/bin/bash -e

# Arbitrary VM name
vmname="win7"

# Your host username (you can run this as root, but check README and/or just edit
# this script for that)
username=$(whoami)

# Your host machine hostname (for Synergy; note that your synergy server
# inside the VM needs to be setup to expect this client)
hostname=$(hostname)

# Drives being used. Make sure the Windows drive is first
drives=("/dev/sdd" "/dev/sde")

# TAP interface being created/bridged. Name it whatever
veth="vmtap0"

# Name of an existing bridge that already includes your ethernet connection
bridge="bridge0"

# Amount of memory to grant VM
memory="8G"

# GPU BIOS ROM (possibly not needed)
romfile="/storage/vms/nvidia_msi_gtx970.rom"

# USB keyboard ID (check lsusb)
keyboard_id="1b1c:1b07"

# USB mouse ID (check lsusb)
mouse_id="046d:c085"

# USB microphone ID (check lsusb)
microphone_id="0d8c:0005"

# GPU VFIO ids (check your iommu groups)
vfio_id_1="0f:00.0"
vfio_id_2="0f:00.1"

# Default primary monitor, also the one to be used by the VM
primary_monitor="DisplayPort-0"
primary_monitor_resolution="2560x1440"

# Secondary monitor that remains
secondary_monitor="DVI-D-0"
secondary_monitor_resolution="1920x1200"

# Guest VM IP (for synergy)
vm_ip="192.168.0.201"

# PulseAudio output
#pulseaudio_sink="alsa_output.pci-0000_12_00.3.analog-surround-51"
pulseaudio_sink="bluez_sink.00_16_94_21_C1_07.a2dp_sink"

# PulseAudio input
# FIXME: This is currently useless
pulseaudio_source="alsa_input.usb-BLUE_MICROPHONE_Blue_Snowball_201705-00.analog-mono"

# Socket for QEMU console
socket="/home/gig/qemu-win7.sock"

##############################################################################
# Standard PulseAudio ENV variables
# You can find your sink/source by running:
#
# $ pactl list

export QEMU_AUDIO_DRV="pa"
export QEMU_PA_SAMPLES=1024
export QEMU_PA_SINK="$pulseaudio_sink"
export QEMU_PA_SOURCE="$pulseaudio_source"
# Uncomment if running as root
#export QEMU_PA_SERVER="/run/user/1000/pulse/native"

##############################################################################

setup() {
  echo ">>>> Beginning VM setup"

  # Remove these if running as root
  for drive in $drives; do
    echo "---> Fixing $drive permissions"
    sudo chmod g-w $drive
    sudo chown $username $drive
  done

  echo "---> Creating $veth tap device"
  sudo ip tuntap add dev $veth mode tap
  sudo ip link set $veth up
  # think this is useless actually
  sudo ip addr add 192.168.0.223 dev $veth
  echo "---> Adding $veth to $bridge"
  sudo brctl addif $bridge $veth

  echo "---> Starting synergy"
  synergyc --debug ERROR --name $hostname $vm_ip

  echo "---> Switching displays"
  xrandr --output $primary_monitor --off
  xrandr --output $secondary_monitor --mode $secondary_monitor_resolution --pos 0x0 --primary
}

teardown() {
  # Still care if things fail here, but the whole list should be run through.
  set +e

  echo "---> Removing $veth from $bridge"
  sudo brctl delif $bridge $veth
  echo "---> Removing $veth tap device"
  sudo ip link set $veth down
  sudo ip tuntap del dev $veth mode tap

  echo "---> Killing synergy"
  killall synergyc

  echo "---> Restoring displays"
  xrandr --output $primary_monitor --mode $primary_monitor_resolution --pos 0x0 --primary
  xrandr --output $secondary_monitor --mode $secondary_monitor_resolution --pos $(echo -n $primary_monitor_resolution | sed 's/x.*//g')x0

  # These might not be necessary for you, but after shutting down the VM and
  # regaining control of these USB devices, these settings (keymap, mouse sens)
  # need to be re-set also...
  echo "---> Restoring USB keyboard and mouse settings (layout, rates, sensitivity)"
  setxkbmap be
  xset r rate 350 40
  xset m 0 0
  # Change this to the name of your mouse (if needed at all)
  while read -r mouse_id; do
    xinput set-prop $mouse_id 'libinput Accel Speed' -0.66 >/dev/null 2<&1
  done <<< $(xinput list | grep "G Pro.*pointer" | awk '{print $8}' | sed "s/id=//")

  echo "[OK] VM teardown completed"
}

quit() {
  # Install openbsd-netcat for this.
  echo system_powerdown | nc -U $socket
  echo "!!!! Terminated"
}

run_qemu() {
  echo "---> Starting QEMU"

  drive_options=""
  for i in "${!drives[@]}"; do
    drive_options=" $drive_options -drive file=${drives[$i]},if=virtio,index=$i"
  done

  # Note that kvm=off and hv_vendor_id=whatever on the -cpu line are only
  # necessary for nvidia GPUs, to prevent their drivers from self-sabotaging
  # once they detect a virtualized environment (Error 43).
  exec qemu-system-x86_64 \
    -enable-kvm \
    -m $memory \
    -soundhw hda \
    -cpu host,kvm=off,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vendor_id=whatever \
    -smp cores=4,threads=2,sockets=1,maxcpus=12 \
    -vcpu vcpunum=0,affinity=1 \
    -vcpu vcpunum=1,affinity=3 \
    -vcpu vcpunum=2,affinity=5 \
    -vcpu vcpunum=3,affinity=7 \
    -vcpu vcpunum=4,affinity=9 \
    -vcpu vcpunum=5,affinity=11 \
    -vcpu vcpunum=6,affinity=13 \
    -vcpu vcpunum=7,affinity=15 \
    $drive_options \
    -bios /usr/share/qemu/bios.bin \
    -machine q35,accel=kvm \
    -name $vmname \
    -net nic,model=virtio \
    -net tap,ifname=$veth,script=no,downscript=no \
    -usb -usbdevice host:$keyboard_id -usbdevice host:$mouse_id -usbdevice host:$microphone_id \
    -device usb-kbd -device usb-mouse \
    -device vfio-pci,host=$vfio_id_1,multifunction=on,x-vga=on \
    -device vfio-pci,host=$vfio_id_2 \
    -nographic \
    -vga none \
    -monitor unix:$socket,server,nowait
    #-device vfio-pci,host=$vfio_id_1,multifunction=on,romfile=$romfile,x-vga=on \
    #-device virtio-mouse-pci,id=input0 \
    #-device virtio-keyboard-pci,id=input1 \
    #-object input-linux,id=mouse1,evdev=$mouse \
    #-object input-linux,id=kbd1,evdev=$kbd2 \
    #-object input-linux,id=kbd2,evdev=$kbd,grab_all=on,repeat=on \
    #-net bridge,br=$bridge \
    #-net user \
    #-net user,hostfwd=tcp::42323-:24800 \
    #-rtc base=localtime,clock=host \
}

##############################################################################
# Run stuff

setup

(run_qemu) &

trap "teardown" EXIT ERR INT
trap "quit" TERM

wait
