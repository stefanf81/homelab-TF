# tflint configuration. The bundled terraform ruleset needs no network or init.
# The bpg/proxmox provider ships no tflint ruleset, so only core rules apply.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
