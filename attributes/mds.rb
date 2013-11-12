case node['platform']
when 'ubuntu'
  default["ceph"]["mds"]["init_style"] = "upstart"
else
  default["ceph"]["mds"]["init_style"] = "sysvinit"
end
default["ceph"]["mds"]["secret_file"] = "/etc/chef/secrets/ceph_mds"
