test_clustering_membership() {
  setup_clustering_bridge
  prefix="lxd$$"
  bridge="${prefix}"

  setup_clustering_netns 1
  LXD_ONE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_ONE_DIR}"
  ns1="${prefix}1"
  spawn_lxd_and_bootstrap_cluster "${ns1}" "${bridge}" "${LXD_ONE_DIR}"

  # Add a newline at the end of each line. YAML as weird rules..
  cert=$(sed ':a;N;$!ba;s/\n/\n\n/g' "${LXD_ONE_DIR}/server.crt")

  # Spawn a second node
  setup_clustering_netns 2
  LXD_TWO_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_TWO_DIR}"
  ns2="${prefix}2"
  spawn_lxd_and_join_cluster "${ns2}" "${bridge}" "${cert}" 2 1 "${LXD_TWO_DIR}"

  # Configuration keys can be changed on any node.
  LXD_DIR="${LXD_TWO_DIR}" lxc config set cluster.offline_threshold 30
  LXD_DIR="${LXD_ONE_DIR}" lxc info | grep -q 'cluster.offline_threshold: "30"'
  LXD_DIR="${LXD_TWO_DIR}" lxc info | grep -q 'cluster.offline_threshold: "30"'

  # The preseeded network bridge exists on all nodes.
  ns1_pid="$(cat "${TEST_DIR}/ns/${ns1}/PID")"
  ns2_pid="$(cat "${TEST_DIR}/ns/${ns2}/PID")"
  nsenter -m -n -t "${ns1_pid}" -- ip link show "${bridge}" > /dev/null
  nsenter -m -n -t "${ns2_pid}" -- ip link show "${bridge}" > /dev/null

  # Create a pending network and pool, to show that they are not
  # considered when checking if the joining node has all the required
  # networks and pools.
  LXD_DIR="${LXD_TWO_DIR}" lxc storage create pool1 dir --target node1
  LXD_DIR="${LXD_ONE_DIR}" lxc network create net1 --target node2

  # Spawn a third node, using the non-leader node2 as join target.
  setup_clustering_netns 3
  LXD_THREE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_THREE_DIR}"
  ns3="${prefix}3"
  spawn_lxd_and_join_cluster "${ns3}" "${bridge}" "${cert}" 3 2 "${LXD_THREE_DIR}"

  # Spawn a fourth node, this will be a non-database node.
  setup_clustering_netns 4
  LXD_FOUR_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_FOUR_DIR}"
  ns4="${prefix}4"
  spawn_lxd_and_join_cluster "${ns4}" "${bridge}" "${cert}" 4 1 "${LXD_FOUR_DIR}"

  # Spawn a fifth node, using non-database node4 as join target.
  setup_clustering_netns 5
  LXD_FIVE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_FIVE_DIR}"
  ns5="${prefix}5"
  spawn_lxd_and_join_cluster "${ns5}" "${bridge}" "${cert}" 5 4 "${LXD_FIVE_DIR}"

  # List all nodes, using clients points to different nodes and
  # checking which are database nodes and which are not.
  LXD_DIR="${LXD_THREE_DIR}" lxc cluster list
  LXD_DIR="${LXD_THREE_DIR}" lxc cluster list | grep "node1" | grep -q "YES"
  LXD_DIR="${LXD_FOUR_DIR}" lxc cluster list | grep "node2" | grep -q "YES"
  LXD_DIR="${LXD_ONE_DIR}" lxc cluster list | grep "node3" | grep -q "YES"
  LXD_DIR="${LXD_TWO_DIR}" lxc cluster list | grep "node4" | grep -q "NO"
  LXD_DIR="${LXD_FIVE_DIR}" lxc cluster list | grep "node5" | grep -q "NO"

  # Show a single node
  LXD_DIR="${LXD_TWO_DIR}" lxc cluster show node5 | grep -q "node5"

  # Client certificate are shared across all nodes.
  LXD_DIR="${LXD_ONE_DIR}" lxc remote add cluster 10.1.1.101:8443 --accept-certificate --password=sekret
  LXD_DIR="${LXD_ONE_DIR}" lxc remote set-url cluster https://10.1.1.102:8443
  lxc network list cluster: | grep -q "${bridge}"

  # Shutdown a non-database node, and wait a few seconds so it will be
  # detected as down.
  LXD_DIR="${LXD_ONE_DIR}" lxc config set cluster.offline_threshold 5
  LXD_DIR="${LXD_FIVE_DIR}" lxd shutdown
  sleep 10
  LXD_DIR="${LXD_THREE_DIR}" lxc cluster list | grep "node5" | grep -q "OFFLINE"
  LXD_DIR="${LXD_TWO_DIR}" lxc config set cluster.offline_threshold 20

  # Trying to delete the preseeded network now fails, because a node is degraded.
  ! LXD_DIR="${LXD_TWO_DIR}" lxc network delete "${bridge}"

  # Force the removal of the degraded node.
  LXD_DIR="${LXD_THREE_DIR}" lxc cluster remove node5 --force

  # Now the preseeded network can be deleted, and all nodes are
  # notified.
  LXD_DIR="${LXD_TWO_DIR}" lxc network delete "${bridge}"

  # Rename a node using the pre-existing name.
  LXD_DIR="${LXD_THREE_DIR}" lxc cluster rename node4 node5

  # Trying to delete a container which is the only one with a copy of
  # an image results in an error
  LXD_DIR="${LXD_FOUR_DIR}" ensure_import_testimage
  ! LXD_DIR="${LXD_FOUR_DIR}" lxc cluster remove node5
  LXD_DIR="${LXD_TWO_DIR}" lxc image delete testimage

  # Remove a node gracefully.
  LXD_DIR="${LXD_FOUR_DIR}" lxc cluster remove node5
  ! LXD_DIR="${LXD_FOUR_DIR}" lxc cluster list

  LXD_DIR="${LXD_FOUR_DIR}" lxd shutdown
  LXD_DIR="${LXD_THREE_DIR}" lxd shutdown
  LXD_DIR="${LXD_TWO_DIR}" lxd shutdown
  LXD_DIR="${LXD_ONE_DIR}" lxd shutdown
  sleep 2
  rm -f "${LXD_FIVE_DIR}/unix.socket"
  rm -f "${LXD_FOUR_DIR}/unix.socket"
  rm -f "${LXD_THREE_DIR}/unix.socket"
  rm -f "${LXD_TWO_DIR}/unix.socket"
  rm -f "${LXD_ONE_DIR}/unix.socket"

  teardown_clustering_netns
  teardown_clustering_bridge
}

test_clustering_containers() {
  setup_clustering_bridge
  prefix="lxd$$"
  bridge="${prefix}"

  setup_clustering_netns 1
  LXD_ONE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_ONE_DIR}"
  ns1="${prefix}1"
  spawn_lxd_and_bootstrap_cluster "${ns1}" "${bridge}" "${LXD_ONE_DIR}"

  # Add a newline at the end of each line. YAML as weird rules..
  cert=$(sed ':a;N;$!ba;s/\n/\n\n/g' "${LXD_ONE_DIR}/server.crt")

  # Spawn a second node
  setup_clustering_netns 2
  LXD_TWO_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_TWO_DIR}"
  ns2="${prefix}2"
  spawn_lxd_and_join_cluster "${ns2}" "${bridge}" "${cert}" 2 1 "${LXD_TWO_DIR}"

  # Spawn a third node
  setup_clustering_netns 3
  LXD_THREE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_THREE_DIR}"
  ns3="${prefix}3"
  spawn_lxd_and_join_cluster "${ns3}" "${bridge}" "${cert}" 3 1 "${LXD_THREE_DIR}"

  # Init a container on node2, using a client connected to node1
  LXD_DIR="${LXD_TWO_DIR}" ensure_import_testimage
  LXD_DIR="${LXD_ONE_DIR}" lxc init --target node2 testimage foo

  # The container is visible through both nodes
  LXD_DIR="${LXD_ONE_DIR}" lxc list | grep foo | grep -q STOPPED
  LXD_DIR="${LXD_ONE_DIR}" lxc list | grep foo | grep -q node2
  LXD_DIR="${LXD_TWO_DIR}" lxc list | grep foo | grep -q STOPPED

  # A Location: field indicates on which node the container is running
  LXD_DIR="${LXD_ONE_DIR}" lxc info foo | grep -q "Location: node2"

  # Start the container via node1
  LXD_DIR="${LXD_ONE_DIR}" lxc start foo
  LXD_DIR="${LXD_TWO_DIR}" lxc info foo | grep -q "Status: Running"
  LXD_DIR="${LXD_ONE_DIR}" lxc list | grep foo | grep -q RUNNING

  # Trying to delete a node which has container results in an error
  ! LXD_DIR="${LXD_ONE_DIR}" lxc cluster remove node2

  # Exec a command in the container via node1
  LXD_DIR="${LXD_ONE_DIR}" lxc exec foo ls / | grep -q proc

  # Pull, push and delete files from the container via node1
  ! LXD_DIR="${LXD_ONE_DIR}" lxc file pull foo/non-existing-file "${TEST_DIR}/non-existing-file"
  mkdir "${TEST_DIR}/hello-world"
  echo "hello world" > "${TEST_DIR}/hello-world/text"
  LXD_DIR="${LXD_ONE_DIR}" lxc file push "${TEST_DIR}/hello-world/text" foo/hello-world-text
  LXD_DIR="${LXD_ONE_DIR}" lxc file pull foo/hello-world-text "${TEST_DIR}/hello-world-text"
  grep -q "hello world" "${TEST_DIR}/hello-world-text"
  rm "${TEST_DIR}/hello-world-text"
  LXD_DIR="${LXD_ONE_DIR}" lxc file push --recursive "${TEST_DIR}/hello-world" foo/
  rm -r "${TEST_DIR}/hello-world"
  LXD_DIR="${LXD_ONE_DIR}" lxc file pull --recursive foo/hello-world "${TEST_DIR}"
  grep -q "hello world" "${TEST_DIR}/hello-world/text"
  rm -r "${TEST_DIR}/hello-world"
  LXD_DIR="${LXD_ONE_DIR}" lxc file delete foo/hello-world/text
  ! LXD_DIR="${LXD_ONE_DIR}" lxc file pull foo/hello-world/text "${TEST_DIR}/hello-world-text"

  # Stop the container via node1
  LXD_DIR="${LXD_ONE_DIR}" lxc stop foo --force

  # Rename the container via node1
  LXD_DIR="${LXD_ONE_DIR}" lxc rename foo foo2
  LXD_DIR="${LXD_TWO_DIR}" lxc list | grep -q foo2
  LXD_DIR="${LXD_ONE_DIR}" lxc rename foo2 foo

  # Show lxc.log via node1
  LXD_DIR="${LXD_ONE_DIR}" lxc info --show-log foo | grep -q Log

  # Create, rename and delete a snapshot of the container via node1
  LXD_DIR="${LXD_ONE_DIR}" lxc snapshot foo foo-bak
  LXD_DIR="${LXD_ONE_DIR}" lxc info foo | grep -q foo-bak
  LXD_DIR="${LXD_ONE_DIR}" lxc rename foo/foo-bak foo/foo-bak-2
  LXD_DIR="${LXD_ONE_DIR}" lxc delete foo/foo-bak-2
  ! LXD_DIR="${LXD_ONE_DIR}" lxc info foo | grep -q foo-bak-2

  # Export from node1 the image that was imported on node2
  LXD_DIR="${LXD_ONE_DIR}" lxc image export testimage "${TEST_DIR}/testimage"
  rm "${TEST_DIR}/testimage.tar.xz"

  # Create a container on node1 using the image that was stored on
  # node2.
  LXD_DIR="${LXD_TWO_DIR}" lxc launch --target node1 testimage bar
  LXD_DIR="${LXD_TWO_DIR}" lxc stop bar --force
  LXD_DIR="${LXD_ONE_DIR}" lxc delete bar
  ! LXD_DIR="${LXD_TWO_DIR}" lxc list | grep -q bar

  # Create a container on node1 using a snapshot from node2.
  LXD_DIR="${LXD_ONE_DIR}" lxc snapshot foo foo-bak
  LXD_DIR="${LXD_TWO_DIR}" lxc copy foo/foo-bak bar --target node1
  LXD_DIR="${LXD_TWO_DIR}" lxc info bar | grep -q "Location: node1"
  LXD_DIR="${LXD_THREE_DIR}" lxc delete bar

  # Copy the container on node2 to node3, using a client connected to
  # node1.
  LXD_DIR="${LXD_ONE_DIR}" lxc copy foo bar --target node3
  LXD_DIR="${LXD_TWO_DIR}" lxc info bar | grep -q "Location: node3"

  # Move the container on node3 to node1, using a client connected to
  # node2.
  LXD_DIR="${LXD_TWO_DIR}" lxc move bar egg --target node1
  LXD_DIR="${LXD_ONE_DIR}" lxc info egg | grep -q "Location: node1"
  LXD_DIR="${LXD_THREE_DIR}" lxc delete egg

  # Delete the network now, since we're going to shutdown node2 and it
  # won't be possible afterwise.
  LXD_DIR="${LXD_TWO_DIR}" lxc network delete "${bridge}"

  # Shutdown node 2, wait for it to be considered offline, and list
  # containers.
  LXD_DIR="${LXD_THREE_DIR}" lxc config set cluster.offline_threshold 5
  LXD_DIR="${LXD_TWO_DIR}" lxd shutdown
  sleep 10
  LXD_DIR="${LXD_ONE_DIR}" lxc list | grep foo | grep -q ERROR
  LXD_DIR="${LXD_ONE_DIR}" lxc config set cluster.offline_threshold 20

  # Start a container without specifying any target. It will be placed
  # on node1 since node2 is offline and both node1 and node3 have zero
  # containers, but node1 has a lower node ID.
  LXD_DIR="${LXD_THREE_DIR}" lxc launch testimage bar
  LXD_DIR="${LXD_THREE_DIR}" lxc info bar | grep -q "Location: node1"

  # Start a container without specifying any target. It will be placed
  # on node3 since node2 is offline and node1 already has a container.
  LXD_DIR="${LXD_THREE_DIR}" lxc launch testimage egg
  LXD_DIR="${LXD_THREE_DIR}" lxc info egg | grep -q "Location: node3"

  LXD_DIR="${LXD_ONE_DIR}" lxc stop egg --force
  LXD_DIR="${LXD_ONE_DIR}" lxc stop bar --force

  LXD_DIR="${LXD_THREE_DIR}" lxd shutdown
  LXD_DIR="${LXD_ONE_DIR}" lxd shutdown
  sleep 2
  rm -f "${LXD_THREE_DIR}/unix.socket"
  rm -f "${LXD_TWO_DIR}/unix.socket"
  rm -f "${LXD_ONE_DIR}/unix.socket"

  teardown_clustering_netns
  teardown_clustering_bridge
}

test_clustering_storage() {
  setup_clustering_bridge
  prefix="lxd$$"
  bridge="${prefix}"

  # The random storage backend is not supported in clustering tests,
  # since we need to have the same storage driver on all nodes.
  driver="${LXD_BACKEND}"
  if [ "${driver}" = "random" ] || [ "${driver}" = "lvm" ]; then
    driver="dir"
  fi

  setup_clustering_netns 1
  LXD_ONE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_ONE_DIR}"
  ns1="${prefix}1"
  spawn_lxd_and_bootstrap_cluster "${ns1}" "${bridge}" "${LXD_ONE_DIR}" "${driver}"

  # The state of the preseeded storage pool shows up as CREATED
  LXD_DIR="${LXD_ONE_DIR}" lxc storage list | grep data | grep -q CREATED

  # Add a newline at the end of each line. YAML as weird rules..
  cert=$(sed ':a;N;$!ba;s/\n/\n\n/g' "${LXD_ONE_DIR}/server.crt")

  # Spawn a second node
  setup_clustering_netns 2
  LXD_TWO_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_TWO_DIR}"
  ns2="${prefix}2"
  spawn_lxd_and_join_cluster "${ns2}" "${bridge}" "${cert}" 2 1 "${LXD_TWO_DIR}" "${driver}"

  # The state of the preseeded storage pool is still CREATED
  LXD_DIR="${LXD_ONE_DIR}" lxc storage list | grep data | grep -q CREATED

  # Trying to pass config values other than 'source' results in an error
  ! LXD_DIR="${LXD_ONE_DIR}" lxc storage create pool1 dir source=/foo size=123 --target node1

  # Define storage pools on the two nodes
  driver_config=""
  if [ "${driver}" = "btrfs" ]; then
      driver_config="size=20GB"
  fi
  if [ "${driver}" = "zfs" ]; then
      driver_config="size=20GB"
  fi
  if [ "${driver}" = "ceph" ]; then
      driver_config="source=pool1-$(basename "${TEST_DIR}")"
  fi
  driver_config_node1="${driver_config}"
  driver_config_node2="${driver_config}"
  if [ "${driver}" = "zfs" ]; then
      driver_config_node1="${driver_config_node1} zfs.pool_name=pool1-$(basename "${TEST_DIR}")-${ns1}"
      driver_config_node2="${driver_config_node1} zfs.pool_name=pool1-$(basename "${TEST_DIR}")-${ns2}"
  fi

  if [ -n "${driver_config_node1}" ]; then
    # shellcheck disable=SC2086
    LXD_DIR="${LXD_ONE_DIR}" lxc storage create pool1 "${driver}" ${driver_config_node1} --target node1
  else
    LXD_DIR="${LXD_ONE_DIR}" lxc storage create pool1 "${driver}" --target node1
  fi

  LXD_DIR="${LXD_TWO_DIR}" lxc storage show pool1 | grep -q node1
  ! LXD_DIR="${LXD_TWO_DIR}" lxc storage show pool1 | grep -q node2
  if [ -n "${driver_config_node2}" ]; then
    # shellcheck disable=SC2086
    LXD_DIR="${LXD_ONE_DIR}" lxc storage create pool1 "${driver}" ${driver_config_node2} --target node2
  else
    LXD_DIR="${LXD_ONE_DIR}" lxc storage create pool1 "${driver}" --target node2
  fi
  LXD_DIR="${LXD_ONE_DIR}" lxc storage show pool1 | grep status: | grep -q Pending

  # The source config key is not legal for the final pool creation
  if [ "${driver}" = "dir" ]; then
    ! LXD_DIR="${LXD_ONE_DIR}" lxc storage create pool1 dir source=/foo
  fi

  # Create the storage pool
  if [ "${driver}" = "lvm" ]; then
      LXD_DIR="${LXD_TWO_DIR}" lxc storage create pool1 "${driver}" volume.size=25MB
  elif [ "${driver}" = "ceph" ]; then
      LXD_DIR="${LXD_TWO_DIR}" lxc storage create pool1 "${driver}" volume.size=25MB ceph.osd.pg_num=8
  else
      LXD_DIR="${LXD_TWO_DIR}" lxc storage create pool1 "${driver}"
  fi
  LXD_DIR="${LXD_ONE_DIR}" lxc storage show pool1 | grep status: | grep -q Created

  # The 'source' config key is omitted when showing the cluster
  # configuration, and included when showing the node-specific one.
  ! LXD_DIR="${LXD_TWO_DIR}" lxc storage show pool1 | grep -q source
  source1="$(basename "${LXD_ONE_DIR}")"
  source2="$(basename "${LXD_TWO_DIR}")"
  if [ "${driver}" = "ceph" ]; then
    # For ceph volume the source field is the name of the underlying ceph pool
    source1="pool1-$(basename "${TEST_DIR}")"
    source2="${source1}"
  fi
  LXD_DIR="${LXD_ONE_DIR}" lxc storage show pool1 --target node1 | grep source | grep -q "${source1}"
  LXD_DIR="${LXD_ONE_DIR}" lxc storage show pool1 --target node2 | grep source | grep -q "${source2}"

  # Update the storage pool
  if [ "${driver}" = "dir" ]; then
    LXD_DIR="${LXD_ONE_DIR}" lxc storage set pool1 rsync.bwlimit 10
    LXD_DIR="${LXD_TWO_DIR}" lxc storage show pool1 | grep rsync.bwlimit | grep -q 10
    LXD_DIR="${LXD_TWO_DIR}" lxc storage unset pool1 rsync.bwlimit
    ! LXD_DIR="${LXD_ONE_DIR}" lxc storage show pool1 | grep -q rsync.bwlimit
  fi

  # Test migration of ceph-based containers
  if [ "${driver}" = "ceph" ]; then
    LXD_DIR="${LXD_TWO_DIR}" ensure_import_testimage
    LXD_DIR="${LXD_ONE_DIR}" lxc launch --target node2 -s pool1 testimage foo

    # The container can't be moved if it's running
    ! LXD_DIR="${LXD_TWO_DIR}" lxc move foo --target node1 || false

    # Stop the container and create a snapshot
    LXD_DIR="${LXD_ONE_DIR}" lxc stop foo --force
    LXD_DIR="${LXD_ONE_DIR}" lxc snapshot foo backup

    # Move the container to node1
    LXD_DIR="${LXD_TWO_DIR}" lxc move foo --target node1
    LXD_DIR="${LXD_TWO_DIR}" lxc info foo | grep -q "Location: node1"
    LXD_DIR="${LXD_TWO_DIR}" lxc info foo | grep -q "backup (taken at"

    # Start and stop the container on its new node1 host
    LXD_DIR="${LXD_TWO_DIR}" lxc start foo
    LXD_DIR="${LXD_TWO_DIR}" lxc stop foo --force

    # Init a new container on node2 using the the snapshot on node1
    LXD_DIR="${LXD_ONE_DIR}" lxc copy foo/backup egg --target node2
    LXD_DIR="${LXD_TWO_DIR}" lxc start egg
    LXD_DIR="${LXD_ONE_DIR}" lxc stop egg --force
    LXD_DIR="${LXD_ONE_DIR}" lxc delete egg

    # Spawn a third node
    setup_clustering_netns 3
    LXD_THREE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
    chmod +x "${LXD_THREE_DIR}"
    ns3="${prefix}3"
    spawn_lxd_and_join_cluster "${ns3}" "${bridge}" "${cert}" 3 1 "${LXD_THREE_DIR}" "${driver}"

    # Move the container to node3, renaming it
    LXD_DIR="${LXD_TWO_DIR}" lxc move foo bar --target node3
    LXD_DIR="${LXD_TWO_DIR}" lxc info bar | grep -q "Location: node3"
    LXD_DIR="${LXD_ONE_DIR}" lxc info bar | grep -q "backup (taken at"

    # Shutdown node 3, and wait for it to be considered offline.
    LXD_DIR="${LXD_THREE_DIR}" lxc config set cluster.offline_threshold 5
    LXD_DIR="${LXD_THREE_DIR}" lxd shutdown
    sleep 10

    # Move the container back to node2, even if node3 is offline
    LXD_DIR="${LXD_ONE_DIR}" lxc move bar --target node2
    LXD_DIR="${LXD_ONE_DIR}" lxc info bar | grep -q "Location: node2"
    LXD_DIR="${LXD_TWO_DIR}" lxc info bar | grep -q "backup (taken at"

    # Start and stop the container on its new node2 host
    LXD_DIR="${LXD_TWO_DIR}" lxc start bar
    LXD_DIR="${LXD_ONE_DIR}" lxc stop bar --force

    LXD_DIR="${LXD_ONE_DIR}" lxc config set cluster.offline_threshold 20
    LXD_DIR="${LXD_ONE_DIR}" lxc cluster remove node3 --force

    LXD_DIR="${LXD_ONE_DIR}" lxc delete bar
    LXD_DIR="${LXD_ONE_DIR}" lxc image delete testimage
  fi

  # Delete the storage pool
  LXD_DIR="${LXD_ONE_DIR}" lxc storage delete pool1
  ! LXD_DIR="${LXD_ONE_DIR}" lxc storage list | grep -q pool1

  if [ "${driver}" != "ceph" ]; then
    # Create a volume on node1
    LXD_DIR="${LXD_ONE_DIR}" lxc storage volume create data web
    LXD_DIR="${LXD_ONE_DIR}" lxc storage volume list data | grep -q node1
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume list data | grep -q node1

    # Since the volume name is unique to node1, it's possible to show, rename,
    # get the volume without specifying the --target parameter.
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume show data web | grep -q "location: node1"
    LXD_DIR="${LXD_ONE_DIR}" lxc storage volume rename data web webbaz
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume rename data webbaz web
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume get data web size

    # Create another volume on node2 with the same name of the one on
    # node1.
    LXD_DIR="${LXD_ONE_DIR}" lxc storage volume create --target node2 data web

    # Trying to show, rename or delete the web volume without --target
    # fails, because it's not unique.
    ! LXD_DIR="${LXD_TWO_DIR}" lxc storage volume show data web
    ! LXD_DIR="${LXD_TWO_DIR}" lxc storage volume rename data web webbaz
    ! LXD_DIR="${LXD_TWO_DIR}" lxc storage volume delete data web

    # Specifying the --target parameter shows, renames and deletes the
    # proper volume.
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume show --target node1 data web | grep -q "location: node1"
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume show --target node2 data web | grep -q "location: node2"
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume rename --target node1 data web webbaz
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume rename --target node2 data web webbaz
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume delete --target node2 data webbaz

    # Since now there's only one volume in the pool left named webbaz,
    # it's possible to delete it without specifying --target.
    LXD_DIR="${LXD_TWO_DIR}" lxc storage volume delete data webbaz
  fi

  LXD_DIR="${LXD_ONE_DIR}" lxc profile delete default
  LXD_DIR="${LXD_TWO_DIR}" lxc storage delete data

  LXD_DIR="${LXD_TWO_DIR}" lxd shutdown
  LXD_DIR="${LXD_ONE_DIR}" lxd shutdown
  sleep 2
  rm -f "${LXD_TWO_DIR}/unix.socket"
  rm -f "${LXD_ONE_DIR}/unix.socket"

  teardown_clustering_netns
  teardown_clustering_bridge
}

test_clustering_network() {
  setup_clustering_bridge
  prefix="lxd$$"
  bridge="${prefix}"

  setup_clustering_netns 1
  LXD_ONE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_ONE_DIR}"
  ns1="${prefix}1"
  spawn_lxd_and_bootstrap_cluster "${ns1}" "${bridge}" "${LXD_ONE_DIR}"

  # The state of the preseeded network shows up as CREATED
  LXD_DIR="${LXD_ONE_DIR}" lxc network list | grep "${bridge}" | grep -q CREATED

  # Add a newline at the end of each line. YAML as weird rules..
  cert=$(sed ':a;N;$!ba;s/\n/\n\n/g' "${LXD_ONE_DIR}/server.crt")

  # Spawn a second node
  setup_clustering_netns 2
  LXD_TWO_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_TWO_DIR}"
  ns2="${prefix}2"
  spawn_lxd_and_join_cluster "${ns2}" "${bridge}" "${cert}" 2 1 "${LXD_TWO_DIR}"

  # The state of the preseeded network is still CREATED
  LXD_DIR="${LXD_ONE_DIR}" lxc network list| grep "${bridge}" | grep -q CREATED

  # Trying to pass config values other than
  # 'bridge.external_interfaces' results in an error
  ! LXD_DIR="${LXD_ONE_DIR}" lxc network create foo ipv4.address=auto --target node1

  net="${bridge}x"

  # Define networks on the two nodes
  LXD_DIR="${LXD_ONE_DIR}" lxc network create "${net}" --target node1
  LXD_DIR="${LXD_TWO_DIR}" lxc network show  "${net}" | grep -q node1
  ! LXD_DIR="${LXD_TWO_DIR}" lxc network show "${net}" | grep -q node2
  LXD_DIR="${LXD_ONE_DIR}" lxc network create "${net}" --target node2
  ! LXD_DIR="${LXD_ONE_DIR}" lxc network create "${net}" --target node2
  LXD_DIR="${LXD_ONE_DIR}" lxc network show "${net}" | grep status: | grep -q Pending

  # The bridge.external_interfaces config key is not legal for the final network creation
  ! LXD_DIR="${LXD_ONE_DIR}" lxc network create "${net}" bridge.external_interfaces=foo

  # Create the network
  LXD_DIR="${LXD_TWO_DIR}" lxc network create "${net}"
  LXD_DIR="${LXD_ONE_DIR}" lxc network show "${net}" | grep status: | grep -q Created
  LXD_DIR="${LXD_ONE_DIR}" lxc network show "${net}" --target node2 | grep status: | grep -q Created

  # FIXME: rename the network is not supported with clustering
  ! LXD_DIR="${LXD_TWO_DIR}" lxc network rename "${net}" "${net}-foo"

  # Delete the networks
  LXD_DIR="${LXD_TWO_DIR}" lxc network delete "${net}"
  LXD_DIR="${LXD_TWO_DIR}" lxc network delete "${bridge}"

  LXD_DIR="${LXD_TWO_DIR}" lxd shutdown
  LXD_DIR="${LXD_ONE_DIR}" lxd shutdown
  sleep 2
  rm -f "${LXD_TWO_DIR}/unix.socket"
  rm -f "${LXD_ONE_DIR}/unix.socket"

  teardown_clustering_netns
  teardown_clustering_bridge
}

test_clustering_upgrade() {
  setup_clustering_bridge
  prefix="lxd$$"
  bridge="${prefix}"

  # First, test the upgrade with a 2-node cluster
  setup_clustering_netns 1
  LXD_ONE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_ONE_DIR}"
  ns1="${prefix}1"
  spawn_lxd_and_bootstrap_cluster "${ns1}" "${bridge}" "${LXD_ONE_DIR}"

  # Add a newline at the end of each line. YAML as weird rules..
  cert=$(sed ':a;N;$!ba;s/\n/\n\n/g' "${LXD_ONE_DIR}/server.crt")

  # Spawn a second node
  setup_clustering_netns 2
  LXD_TWO_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_TWO_DIR}"
  ns2="${prefix}2"
  spawn_lxd_and_join_cluster "${ns2}" "${bridge}" "${cert}" 2 1 "${LXD_TWO_DIR}"

  # Respawn the second node, making it believe it has an higher
  # version than it actually has.
  export LXD_ARTIFICIALLY_BUMP_API_EXTENSIONS=1
  shutdown_lxd "${LXD_TWO_DIR}"
  LXD_NETNS="${ns2}" respawn_lxd "${LXD_TWO_DIR}" false

  # The second daemon is blocked waiting for the other to be upgraded
  ! LXD_DIR="${LXD_TWO_DIR}" lxd waitready --timeout=5

  LXD_DIR="${LXD_ONE_DIR}" lxc cluster show node1 | grep -q "message: fully operational"
  LXD_DIR="${LXD_ONE_DIR}" lxc cluster show node2 | grep -q "message: waiting for other nodes to be upgraded"

  # Respawn the first node, so it matches the version the second node
  # believes to have.
  shutdown_lxd "${LXD_ONE_DIR}"
  LXD_NETNS="${ns1}" respawn_lxd "${LXD_ONE_DIR}" true

  # The second daemon has now unblocked
  LXD_DIR="${LXD_TWO_DIR}" lxd waitready --timeout=30

  # The cluster is again operational
  ! LXD_DIR="${LXD_ONE_DIR}" lxc cluster list | grep -q "OFFLINE"

  # Now spawn a third node and test the upgrade with a 3-node cluster.
  setup_clustering_netns 3
  LXD_THREE_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD_THREE_DIR}"
  ns3="${prefix}3"
  spawn_lxd_and_join_cluster "${ns3}" "${bridge}" "${cert}" 3 1 "${LXD_THREE_DIR}"

  # Respawn the second node, making it believe it has an higher
  # version than it actually has.
  export LXD_ARTIFICIALLY_BUMP_API_EXTENSIONS=2
  shutdown_lxd "${LXD_TWO_DIR}"
  LXD_NETNS="${ns2}" respawn_lxd "${LXD_TWO_DIR}" false

  # The second daemon is blocked waiting for the other two to be
  # upgraded
  ! LXD_DIR="${LXD_TWO_DIR}" lxd waitready --timeout=5

  LXD_DIR="${LXD_ONE_DIR}" lxc cluster show node1 | grep -q "message: fully operational"
  LXD_DIR="${LXD_ONE_DIR}" lxc cluster show node2 | grep -q "message: waiting for other nodes to be upgraded"
  LXD_DIR="${LXD_THREE_DIR}" lxc cluster show node3 | grep -q "message: fully operational"

  # Respawn the first node and third node, so they match the version
  # the second node believes to have.
  shutdown_lxd "${LXD_ONE_DIR}"
  LXD_NETNS="${ns1}" respawn_lxd "${LXD_ONE_DIR}" false
  shutdown_lxd "${LXD_THREE_DIR}"
  LXD_NETNS="${ns3}" respawn_lxd "${LXD_THREE_DIR}" true

  # The cluster is again operational
  ! LXD_DIR="${LXD_ONE_DIR}" lxc cluster list | grep -q "OFFLINE"

  LXD_DIR="${LXD_THREE_DIR}" lxd shutdown
  LXD_DIR="${LXD_TWO_DIR}" lxd shutdown
  LXD_DIR="${LXD_ONE_DIR}" lxd shutdown
  sleep 2
  rm -f "${LXD_THREE_DIR}/unix.socket"
  rm -f "${LXD_TWO_DIR}/unix.socket"
  rm -f "${LXD_ONE_DIR}/unix.socket"

  teardown_clustering_netns
  teardown_clustering_bridge
}
