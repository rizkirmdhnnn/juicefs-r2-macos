# JuiceFS client + Samba, supaya volume bisa di-mount native di Finder macOS.
# Samba harus satu container dengan FUSE mount: mount namespace tidak bisa
# dibagi antar container, jadi smbd wajib melihat /mnt/jfs dari dalam sini.
FROM juicedata/mount:ce-v1.4.0

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      samba \
      samba-vfs-modules \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/samba/smb.conf

COPY smb.conf /etc/samba/smb.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
