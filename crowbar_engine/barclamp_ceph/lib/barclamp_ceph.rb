require "barclamp_ceph/engine"

module BarclampCeph

  TABLE_PREFIX = "bc_ceph_"

  def self.table_name_prefix
    TABLE_PREFIX
  end

  def self.genkey
    # This will wind up becoming a randomly-chosen AES128 key.
    randbits = IO.read("/dev/urandom",16)
    t = Time.now
    header = [1,               # CEPH_KEY_AES_128
              t.to_i,          # Seconds since epoch,
              t.nsec,          # Nanoseconds part of create time.
              randbits.length  # In case we want a longer key
             ]
    # Return our properly packed encoded header + the key.
    # This returns a Base64 encoded string.
    [header.pack('vVVv')+randbits].pack("m").strip
  end

end
