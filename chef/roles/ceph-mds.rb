name "ceph-mds"
description "Ceph metadata server"
run_list('recipe[ceph::mds]')
