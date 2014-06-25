include_recipe "ceph::default"
include_recipe "ceph::conf"

node['ceph']['radosgw']['packages'].each do |pck|
  package pck
end

hostname = node['hostname']

if !::File.exist?("/var/lib/ceph/radosgw/ceph-radosgw.#{hostname}/done")

  include_recipe "ceph::radosgw_apache2"

  ceph_client 'radosgw' do
    caps('mon' => 'allow rw', 'osd' => 'allow rwx')
  end

  directory "/var/lib/ceph/radosgw/ceph-radosgw.#{hostname}" do
    recursive true
  end

  file "/var/lib/ceph/radosgw/ceph-radosgw.#{hostname}/done" do
    action :create
  end

  service 'radosgw' do
    case node['ceph']['radosgw']['init_style']
    when 'upstart'
      service_name 'radosgw-all-starter'
      provider Chef::Provider::Service::Upstart
    else
      if node['platform'] == 'debian'
        service_name 'radosgw'
      else
        service_name 'ceph-radosgw'
      end
    end
    supports :restart => true
    action [:enable, :start]
  end
else
  Log.info('Rados Gateway already deployed')
end
