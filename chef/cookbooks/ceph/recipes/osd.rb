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
  action :install
end

service_type = node["ceph"]["osd"]["init_style"]
mons = get_mon_nodes("ceph_bootstrap-osd-secret:*")

if mons.empty? then
  Chef::Log.fatal("No ceph-mon found")
  raise "No ceph-mon found"
elsif mons[0]["ceph"]["bootstrap-osd-secret"].empty?
  Chef::Log.fatal("No authorization keys found")
else

  [ "tmp", "osd", "bootstrap-osd" ].each do |name|
    directory "/var/lib/ceph/#{name}" do
      owner "root"
      group "root"
      mode "0755"
      recursive true
      action :create
    end
  end

  # TODO cluster name
  cluster = 'ceph'

  osd_secret = mons[0]["ceph"]["bootstrap-osd-secret"]

  execute "create bootstrap-osd keyring" do
    command "ceph-authtool '/var/lib/ceph/bootstrap-osd/#{cluster}.keyring' --create-keyring --name=client.bootstrap-osd --add-key='#{osd_secret}'"
  end

  if is_crowbar?
    node["ceph"]["osd_devices"] = [] if node["ceph"]["osd_devices"].nil?
    unclaimed_disks = BarclampLibrary::Barclamp::Inventory::Disk.unclaimed(node).sort
    if node["ceph"]["disk_mode"] == "first" && node["ceph"]["osd_devices"].empty?
      if unclaimed_disks.empty?
        Chef::Log.fatal("There is no suitable disks for ceph")
        raise "There is no suitable disks for ceph"
      else
        disk_list = [unclaimed_disks.first]
      end
    elsif node["ceph"]["disk_mode"] == "all"
      disk_list = unclaimed_disks
    else
      disk_list = ''
    end

    # Now, we have the final list of devices to claim, so claim them
    disk_list.select do |d|
      if d.claim("Ceph")
        Chef::Log.info("Ceph: Claimed #{d.name}")
        node["ceph"]["osd_devices"].push("device" => d.name)
        node.save
      else
        Chef::Log.info("Ceph: Ignoring #{d.name}")
      end
    end

    # Calling ceph-disk-prepare is sufficient for deploying an OSD
    # After ceph-disk-prepare finishes, the new device will be caught
    # by udev which will run ceph-disk-activate on it (udev will map
    # the devices if dm-crypt is used).
    # IMPORTANT:
    #  - Always use the default path for OSD (i.e. /var/lib/ceph/
    # osd/$cluster-$id)
    #  - $cluster should always be ceph
    #  - The --dmcrypt option will be available starting w/ Cuttlefish
    unless disk_list.empty?
      journal_device = ""
      # In the first iteration, check if there are any SSD disks claimed:
      # if so, it will be used as journal device
      # TODO add some option if user wants to do this automatically
      node["ceph"]["osd_devices"].each_with_index do |osd_device,index| && journal_device.empty?
        dev_name = osd_device['device'].gsub("/dev/", "")
        if node[:block_device][dev_name]["rotational"] == "0"
          Log.info("osd: osd_device #{osd_device} is likely SSD: could be used for journal")
          node["ceph"]["osd_devices"][index]["journal"] = true
          journal_device = osd_device['device']
        end
      end

      osd_devices = []
      node["ceph"]["osd_devices"].each_with_index do |osd_device,index|
        if !osd_device["status"].nil?
          Log.info("osd: osd_device #{osd_device} has already been setup.")
          next
        end
        if osd_device["journal"]
          Log.info("osd: osd_device #{osd_device} is for journal, skipping prepare")
          # TODO prepare the journal device now
          next
        end
        create_cmd = "ceph-disk prepare --cluster #{cluster} --zap-disk #{osd_device['device']}"
        create_cmd = create_cmd + " --journal-dev #{journal_device}" unless journal_device.empty?
        if %w(redhat centos).include? node.platform
          # redhat has buggy udev so we have to use workaround from ceph
          b_dev = osd_device['device'].gsub("/dev/", "")
          create_cmd = create_cmd + " && ceph-disk-udev 2 #{b_dev}2 #{b_dev} ; ceph-disk-udev 1 #{b_dev}1 #{b_dev}"
        else
          create_cmd = create_cmd + " && ceph-disk-activate #{osd_device['device']}1"
        end

        execute "Activating Ceph OSD on #{osd_device['device']}" do
          command create_cmd
          action :run
        end

        ruby_block "Get Ceph OSD ID for #{osd_device['device']}" do
          block do
            osd_id = ''
            while osd_id.empty?
              osd_id = get_osd_id(osd_device['device'])
              sleep 1
            end
          end
        end
        node.set["ceph"]["osd_devices"][index]["status"] = "deployed"
        node.set["ceph"]["osd_devices"][index]["journal"] = journal_device unless journal_device.empty?

        execute "Writing Ceph OSD device mappings to fstab" do
          command "tail -n1 /etc/mtab >> /etc/fstab"
          action :run
        end

      end
      node.save

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
        subscribes :restart, resources(:template => "/etc/ceph/ceph.conf")
      end

    end
  end
end
