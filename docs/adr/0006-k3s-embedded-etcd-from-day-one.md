# k3s with embedded etcd from the first node

The cluster starts with one server node on embedded etcd (`clusterInit`) instead of k3s's default SQLite, so that growing to more servers never needs a datastore migration. The planned growth is one, then two, then three servers, with any number of agents. Not implemented yet. Two etcd servers have no fault tolerance (both are needed for quorum, and every reboot waits for a manual unlock, ADR 0004); the user accepted this, and adding the second node as an agent until a third server exists remains an option.
