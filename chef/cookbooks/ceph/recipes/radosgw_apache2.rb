# now including radosgw_apache2.rb code:

# TODO possibly include code from radosgw_apache2_repo.rb (debian only)

# packages from upstream attributes/radosgw_apache2.rb
# TODO merge with packages in the recipe above
packages = []
case node['platform_family']
  when 'debian', 'suse'
    packages = ['libapache2-mod-fastcgi']
  when 'rhel', 'fedora'
    packages = ['mod_fastcgi']
end

packages.each do |pkg|
  package pkg do
    action :install
  end
end

include_recipe 'apache2'

apache_module 'fastcgi' do
  conf true
end

apache_module 'rewrite' do
  conf false
end

web_app 'rgw' do
  template 'rgw.conf.erb'
  server_name node['ceph']['radosgw']['api_fqdn']
  admin_email node['ceph']['radosgw']['admin_email']
  ceph_rgw_addr node['ceph']['radosgw']['rgw_addr']
end

service 'apache2' do
  action :restart
end

template '/var/www/s3gw.fcgi' do
  source 's3gw.fcgi.erb'
  owner 'root'
  group 'root'
  mode '0755'
  variables(
    :ceph_rgw_client => "client.radosgw.#{node['hostname']}"
  )
end
