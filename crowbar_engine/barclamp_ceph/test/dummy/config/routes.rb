Rails.application.routes.draw do

  mount BarclampCeph::Engine => "/barclamp_ceph"
end
