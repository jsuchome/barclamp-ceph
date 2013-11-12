name "ceph-osd"
description "Ceph object store node"
run_list('recipe[ceph::osd]')
