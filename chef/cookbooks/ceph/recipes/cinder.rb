include_recipe "ceph::default"
include_recipe "ceph::conf"

package "python-ceph" do
  action :install
end

# TODO cluster name
cluster = 'ceph'

group "ceph" do
  action :create
end

group "ceph" do
  members "openstack-cinder"
  action :modify
  append true
end

if !File.exists?("/etc/ceph/keyring")
  file "/etc/ceph/keyring" do
    owner "root"
    group "ceph"
    mode 0640
    action :create
  end

  admin_secret = node["ceph"]["admin-secret"]

  execute "create admin keyring" do
    command "ceph-authtool --create-keyring /etc/ceph/keyring --name=client.admin --add-key='#{admin_secret}'"
  end
end

cinder_user = node[:cinder][:volume][:rbd][:user]
cinder_pool = node[:cinder][:volume][:rbd][:pool]

ruby_block "save cinder key in node attributes" do
  block do

    glance_servers = search(:node, "roles:glance-server")
    if glance_servers.length > 0
      glance_pool = glance_servers[0][:glance][:rbd][:store_pool]

      client_key = %x[
        ceph \
          auth get-or-create-key client.'#{cinder_user}' mon 'allow r' \
          osd 'allow class-read object_prefix rbd_children, allow rwx pool='#{cinder_pool}', allow rwx pool='#{glance_pool}''
      ].tr("\n","")
      raise 'adding or getting cinder client key failed' unless $?.exitstatus == 0

    else

      client_key = %x[
        ceph \
          auth get-or-create-key client.'#{cinder_user}' mon 'allow r' \
          osd 'allow class-read object_prefix rbd_children, allow rwx pool='#{cinder_pool}''
      ].tr("\n","")
      raise 'adding or getting cinder client key failed' unless $?.exitstatus == 0

    end

    %x[ ceph-authtool /etc/ceph/ceph.client.'#{cinder_user}'.keyring --create-keyring \
          --name=client.'#{cinder_user}' --add-key='#{client_key}' ]
    raise 'creating cinder keyring failed' unless $?.exitstatus == 0

    node.normal['ceph']['cinder-secret'] = client_key
    node.save

  end
  not_if { node['ceph']['cinder-secret'] }
end

file "/etc/ceph/ceph.client.#{cinder_user}.keyring" do
  owner "root"
  group "openstack-cinder"
  mode 0640
  action :create
end

execute "create new pool" do
  command "ceph osd pool create #{cinder_pool} 128"
end