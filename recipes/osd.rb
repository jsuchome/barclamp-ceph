#
# Author:: Kyle Bader <kyle.bader@dreamhost.com>
# Cookbook Name:: ceph
# Recipe:: osd
#
# Copyright 2011, DreamHost Web Hosting
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# this recipe allows bootstrapping new osds, with help from mon
# Sample environment:
# #knife node edit ceph1
#"osd_devices": [
#   {
#       "device": "/dev/sdc"
#   },
#   {
#       "device": "/dev/sdd",
#       "dmcrypt": true,
#       "journal": "/dev/sdd"
#   }
#]

include_recipe "ceph::default"
include_recipe "ceph::conf"

package 'gdisk' do
  action :upgrade
end

package 'cryptsetup' do
  action :upgrade
end

service_type = node["ceph"]["osd"]["init_style"]

directory "/var/lib/ceph/bootstrap-osd" do
  owner "root"
  group "root"
  mode "0755"
end

# TODO cluster name
cluster = cluster_name
config = node["ceph"]["config"]["osd"]

prepare="ceph-disk prepare --cluster #{cluster} --cluster-uuid #{node["ceph"]["config"]["fsid"]}"
prepare << " --fs-type #{config["fstype"]}"
prepare << " --dmcrypt" if config["encrypt"]
prepare << " --journal-file" if config["journal"] == "file"


osd_secret = if node['ceph']['encrypted_data_bags']
               secret = Chef::EncryptedDataBagItem.load_secret(node["ceph"]["osd"]["secret_file"])
               Chef::EncryptedDataBagItem.load("ceph", "osd", secret)["secret"]
             else
               node["ceph"]["bootstrap-osd"]
             end

keyring = "/var/lib/ceph/bootstrap-osd/#{cluster}.keyring"

execute "format as keyring" do
  command "ceph-authtool '#{keyring}' --create-keyring --name=client.bootstrap-osd --add-key='#{osd_secret}'"
  creates keyring
  not_if do File.exists?(keyring) end
end

osd_devices = Hash.new
encrypt = false
need_start = false

if is_crowbar?
  ruby_block "select new disks for ceph osd" do
    block do
      do_trigger = false
      # Find all disks that do not have any partitions, holders, or filesystems on them.
      targets = Hash.new
      ignore = Hash.new
      Dir.glob("/sys/class/block/*").each do |ent|
        # We only want symlinks
        next unless File.symlink?(ent)
        link = File.readlink(ent).split("/")
        # No virtual or platform devices.
        next if link.include?("virtual") || link.include?("platform")
        # If it is a USB anything, ignore it.
        next if ent =~ /usb/
        # No removable devices
        next if File.exists?(File.join(ent,"removable")) && (IO.read(File.join(ent,"removable")).strip == "1")
        # No devices that have holders or slaves.
        next unless Dir.glob(File.join(ent,"*/holders")).empty?
        next unless Dir.glob(File.join(ent,"*/slaves")).empty?
        # Arrange to ignore any devices with partitions.
        if link[-3] == "block"
          ignore[link[-2]] = true
          next
        end
        # If blkid sees anything on it, ignore it.
        next unless %x{blkid -o value -s TYPE /dev/#{link[-1]}}.strip.empty?
        targets[link[-1]] = true
      end
      # We have a tenative list of targets. Prepare the ones that are not ignored.
      targets.each_key do |disk|
        next if ignore[disk]
        need_start = true
        Chef::Log.info("Ceph OSD: Preparing with #{prepare} /dev/#{disk}")
        system "#{prepare} /dev/#{disk}"
      end
    end
  end
else
  # Calling ceph-disk-prepare is sufficient for deploying an OSD
  # After ceph-disk-prepare finishes, the new device will be caught
  # by udev which will run ceph-disk-activate on it (udev will map
  # the devices if dm-crypt is used).
  # IMPORTANT:
  #  - Always use the default path for OSD (i.e. /var/lib/ceph/
  # osd/$cluster-$id)
  #  - $cluster should always be ceph
  #  - The --dmcrypt option will be available starting w/ Cuttlefish
  unless node["ceph"]["osd_devices"].nil?
    node["ceph"]["osd_devices"].each_with_index do |osd_device,index|
      if !osd_device["status"].nil?
        Log.info("osd: osd_device #{osd_device} has already been setup.")
        next
      end
      need_start = true
      dmcrypt = ""
      if osd_device["encrypted"] == true
        dmcrypt = "--dmcrypt"
      end
      create_cmd = "ceph-disk-prepare #{dmcrypt} #{osd_device['device']} #{osd_device['journal']}"
      if osd_device["type"] == "directory"
        directory osd_device["device"] do
          owner "root"
          group "root"
          recursive true
        end
        create_cmd << " && ceph-disk-activate #{osd_device['device']}"
      end
      execute "Creating Ceph OSD on #{osd_device['device']}" do
        command create_cmd
        action :run
        notifies :create, "ruby_block[save osd_device status #{index}]"
      end
      # we add this status to the node env
      # so that we can implement recreate
      # and/or delete functionalities in the
      # future.
      ruby_block "save osd_device status #{index}" do
        block do
          node.normal["ceph"]["osd_devices"][index]["status"] = "deployed"
          node.save
        end
        action :nothing
      end
    end
  else
      Log.info('node["ceph"]["osd_devices"] empty')
  end
end

Dir.glob("/var/lib/ceph/osd/*").each do |d|
  next unless File.exists?(File.join(d,"fsid"))
  [service_type,"done"].each do |f|
    file File.join(d,f) do
      action :create_if_missing
    end
  end
end

service "ceph_osd" do
  case service_type
  when "upstart"
    service_name "ceph-osd-all-starter"
    provider Chef::Provider::Service::Upstart
  else
    service_name "ceph"
  end
  action [ :enable, :start ]
  supports :restart => true
  only_if do need_start end
end
