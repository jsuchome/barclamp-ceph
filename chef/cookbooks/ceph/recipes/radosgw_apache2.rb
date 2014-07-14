if node['ceph']['radosgw']['use_apache_fork'] == true
  case node['lsb']['codename']
  when 'precise', 'oneiric'
    apt_repository 'ceph-apache2' do
      repo_name 'ceph-apache2'
      uri "http://gitbuilder.ceph.com/apache2-deb-#{node['lsb']['codename']}-x86_64-basic/ref/master"
      distribution node['lsb']['codename']
      components ['main']
      key 'https://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/autobuild.asc'
    end
    apt_repository 'ceph-modfastcgi' do
      repo_name 'ceph-modfastcgi'
      uri "http://gitbuilder.ceph.com/libapache-mod-fastcgi-deb-#{node['lsb']['codename']}-x86_64-basic/ref/master"
      distribution node['lsb']['codename']
      components ['main']
      key 'https://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/autobuild.asc'
    end
  else
    Log.info("Ceph's Apache and Apache FastCGI forks not available for this distribution")
  end
end

packages = []
case node['platform_family']
  when 'debian'
    packages = ['libapache2-mod-fastcgi']
  when 'rhel', 'fedora'
    packages = ['mod_fastcgi']
  when 'suse'
    packages = ['apache2-mod_fastcgi']
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
end

service 'apache2' do
  action :restart
end

directory node['ceph']['radosgw']['path'] do
  owner node[:apache][:user]
  group node[:apache][:group]
  mode "0755"
  action :create
end

template node['ceph']['radosgw']['path'] + '/s3gw.fcgi' do
  source 's3gw.fcgi.erb'
  owner 'root'
  group 'root'
  mode '0755'
  variables(
    :ceph_rgw_client => "client.radosgw.#{node['hostname']}"
  )
end
