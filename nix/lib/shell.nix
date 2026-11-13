# Bash functions shared by the oneshots of the subsystems (OpenBao's, the
# Collector's key copy, Agent Substrate's install, the platform
# PostgreSQL's credentials). They wait for what they need for a bounded
# time and then fail, so that a deployment reports the failed unit instead
# of waiting for it.
{
  # wait_until <seconds> <what> <command>...: runs the command every 2
  # seconds until it succeeds; fails after <seconds>.
  waitUntil = ''
    wait_until() {
      local deadline=$((SECONDS + $1)) what=$2
      shift 2
      until "$@"; do
        if ((SECONDS >= deadline)); then
          echo "Gave up waiting for $what." >&2
          return 1
        fi
        sleep 2
      done
    }
  '';

  # api_ready: whether the k3s API server answers with the admin kubeconfig
  # in $KUBECONFIG. `k3s` is the path of the k3s binary.
  apiReady = k3s: ''
    api_ready() {
      [[ -s $KUBECONFIG ]] && ${k3s} kubectl get --raw /readyz >/dev/null 2>&1
    }
  '';
}
