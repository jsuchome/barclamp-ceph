require 'ipaddr'
require 'json'

def is_crowbar?()
  return defined?(Chef::Recipe::Barclamp) != nil
end

def get_mon_nodes(extra_search=nil)
  if is_crowbar?
    mon_roles = search(:role, 'name:crowbar-* AND run_list:role\[ceph-mon\]')
    if not mon_roles.empty?
      search_string = mon_roles.map { |role_object| "roles:"+role_object.name }.join(' OR ')
    end
  else
    search_string = "roles:ceph-mon AND chef_environment:#{node.chef_environment}"
  end

  if not extra_search.nil?
    search_string = "(#{search_string}) AND (#{extra_search})"
  end
  mons = search(:node, search_string)
  return mons
end

# If public-network is specified
# we need to search for the monitor IP
# in the node environment.
# 1. We look if the network is IPv6 or IPv4
# 2. We look for a route matching the network
# 3. We grab the IP and return it with the port
def find_node_ip_in_network(network, nodeish=nil)
  nodeish = node unless nodeish
  net = IPAddr.new(network)
  nodeish["network"]["interfaces"].each do |iface|
    if iface[1]["routes"].nil?
      next
    end
    if net.ipv4?
      iface[1]["routes"].each_with_index do |route, index|
        if iface[1]["routes"][index]["destination"] == network
          return "#{iface[1]["routes"][index]["src"]}:6789"
        end
      end
    else
      # Here we are getting an IPv6. We assume that
      # the configuration is stateful.
      # For this configuration to not fail in a stateless
      # configuration, you should run:
      #  echo "0" > /proc/sys/net/ipv6/conf/*/use_tempaddr
      # on each server, this will disabe temporary addresses
      # See: http://en.wikipedia.org/wiki/IPv6_address#Temporary_addresses
      iface[1]["routes"].each_with_index do |route, index|
        if iface[1]["routes"][index]["destination"] == network
          iface[1]["addresses"].each do |k,v|
            if v["scope"] == "Global" and v["family"] == "inet6"
              return "[#{k}]:6789"
            end
          end
        end
      end
    end
  end
end

def get_mon_addresses()
  mon_ips = []

  if File.exists?("/var/run/ceph/ceph-mon.#{node['hostname']}.asok")
    mon_ips = get_quorum_members_ips()
  else
    mons = []
    # make sure if this node runs ceph-mon, it's always included even if
    # search is laggy; put it first in the hopes that clients will talk
    # primarily to local node
    if node['roles'].include? 'ceph-mon'
      mons << node
    end

    mons += get_mon_nodes()
    if is_crowbar?
      mon_ips = mons.map { |node| Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address }
    else
      if node['ceph']['config'] && node['ceph']['config']['public-network']
        mon_ips = mons.map { |nodeish| find_node_ip_in_network(node['ceph']['config']['public-network'], nodeish) }
      else
        mon_ips = mons.map { |node| node['ipaddress'] + ":6789" }
      end
    end
  end
  return mon_ips.uniq
end

def get_quorum_members_ips()
  mon_ips = []
  mon_status = %x[ceph --admin-daemon /var/run/ceph/ceph-mon.#{node['hostname']}.asok mon_status]
  raise 'getting quorum members failed' unless $?.exitstatus == 0

  mons = JSON.parse(mon_status)['monmap']['mons']
  mons.each do |k|
    mon_ips.push(k['addr'][0..-3])
  end
  return mon_ips
end

QUORUM_STATES = ['leader', 'peon']
def have_quorum?()
    # "ceph auth get-or-create-key" would hang if the monitor wasn't
    # in quorum yet, which is highly likely on the first run. This
    # helper lets us delay the key generation into the next
    # chef-client run, instead of hanging.
    #
    # Also, as the UNIX domain socket connection has no timeout logic
    # in the ceph tool, this exits immediately if the ceph-mon is not
    # running for any reason; trying to connect via TCP/IP would wait
    # for a relatively long timeout.
    mon_status = %x[ceph --admin-daemon /var/run/ceph/ceph-mon.#{node['hostname']}.asok mon_status]
    raise 'getting monitor state failed' unless $?.exitstatus == 0
    state = JSON.parse(mon_status)['state']
    return QUORUM_STATES.include?(state)
end

def get_osd_id(device)
  osd_path = %x[mount | grep #{device} | awk '{print $3}'].tr("\n","")
  osd_id = %x[cat #{osd_path}/whoami].tr("\n","")
  return osd_id
end

def get_osd_nodes()
  osds = []
  if is_crowbar?
    osd_roles = search(:role, 'name:crowbar-* AND run_list:role\[ceph-osd\]')
    if not osd_roles.empty?
      search_string = osd_roles.map { |role_object| "roles:"+role_object.name }.join(' OR ')
    end
  else
    search_string = "roles:ceph-osd AND chef_environment:#{node.chef_environment}"
  end

  search(:node, search_string).each do |node|
    port_counter = 6799
    cluster_addr = ''
    public_addr = ''

    public_addr = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
    cluster_addr = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "storage").address    

    osd = {} 
    osd[:hostname] = node.name.split('.')[0]
    osd[:cluster_addr] = cluster_addr
    osd[:cluster_port] = (port_counter += 1)
    osd[:public_addr] = public_addr
    osd[:public_port] = (port_counter += 1)
    osds << osd    
  end

  return osds
end

def mon_secret
  monitor_key = ''
  if node['ceph']['monitor-secret'].empty?
    while monitor_key.empty?
      get_mon_nodes.each do |mon|
        unless mon['ceph']['monitor-secret'].empty?
          monitor_key = mon['ceph']['monitor-secret']
          break
        end
      end
    end
  else
    monitor_key = node['ceph']['monitor-secret']
  end

  monitor_key
end

def add_ssd_part(device)
  sgdisk_lst = Mixlib::ShellOut.new("sgdisk -p #{device}")
  sgdisk_out = sgdisk_lst.run_command.stdout
  sgdisk_lst.error!
  ssd_ptable = []

  sgdisk_out.each do |line|
    if /\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S)+ \S+B\s+\S+\s+(.*)/.match(line)
      ssd_part = {}
      ssd_part['part_number'] = $1
      ssd_part['sec_start'] = $2
      ssd_part['sec_end'] = $3
      ssd_part['part_size'] = $4
      ssd_ptable.push(ssd_part)
    end
  end
  
  num = ssd_ptable.length
  sec = ssd_ptable[num - 1]['sec_end'] rescue 0
  pnum = num + 1

  sgdisk_new = Mixlib::ShellOut.new("sgdisk --new=#{pnum}:#{sec}:+10G --change-name=#{pnum}:\"ceph journal #{pnum}\" --randomize-guids #{device}")
  sgdisk_out = sgdisk_new.run_command.stdout
  sgdisk_new.error!
  
  "#{device}" + "#{pnum}"
end
