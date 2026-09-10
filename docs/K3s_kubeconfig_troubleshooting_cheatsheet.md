# K3s / kubectl Kubeconfig Troubleshooting Cheat Sheet

## Check the current kubeconfig

``` bash
kubectl config current-context
kubectl config view
kubectl config view --raw
echo $KUBECONFIG
```

If `KUBECONFIG` is empty, kubectl uses:

``` text
~/.kube/config
```

## Use a specific kubeconfig

``` bash
kubectl --kubeconfig ./kubeconfig.yaml get nodes
kubectl --kubeconfig ./kubeconfig.yaml config current-context
export KUBECONFIG=$PWD/kubeconfig.yaml
```

## Copy the K3s kubeconfig from the server

``` bash
ssh -i ~/.ssh/id_rsa ubuntu@192.168.50.55 \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
| sed 's#https://127.0.0.1:6443#https://192.168.50.55:6443#' \
  > ./kubeconfig.yaml
```

## Replace your default kubeconfig

``` bash
cp ./kubeconfig.yaml ~/.kube/config
```

## Validate the kubeconfig

``` bash
kubectl --kubeconfig ./kubeconfig.yaml config current-context
kubectl --kubeconfig ./kubeconfig.yaml get nodes
kubectl --kubeconfig ./kubeconfig.yaml get pods -A
```

## Inspect the kubeconfig

``` bash
head -20 ./kubeconfig.yaml
nl -ba ./kubeconfig.yaml
cat -A ./kubeconfig.yaml
```

## Inspect the kubeconfig on the K3s server

``` bash
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml config current-context
sudo cat /etc/rancher/k3s/k3s.yaml
sudo sed -n '1,30p' /etc/rancher/k3s/k3s.yaml | cat -A
```

## Verify K3s

``` bash
k3s --version
sudo systemctl status k3s
sudo systemctl restart k3s
```

## Check which kubectl you're using

``` bash
which kubectl
type kubectl
```

## See where commands come from

``` bash
which kubectx
which kubens
which kubecolor
compgen -c | grep '^kube'
echo $PATH | tr ':' '\n'
```

## Switch contexts

``` bash
kubectl config get-contexts
kubectl config use-context <context-name>

kubectx
kubectx <context-name>
```

## Common errors

### `yaml: found character that cannot start any token`

Usually caused by: - Markdown code fences - Bad indentation - Tabs
instead of spaces

### `tls: failed to find any PEM data in certificate input`

Usually caused by: - Corrupted `certificate-authority-data` - Corrupted
`client-certificate-data` - Incomplete base64 data - Manually copied
kubeconfig

Best practice: copy the kubeconfig directly from the server via SSH
instead of copying it through a browser or chat.
