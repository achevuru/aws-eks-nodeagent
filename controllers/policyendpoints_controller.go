/*
Copyright 2023.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controllers

import (
	"context"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	policyk8sawsv1 "nodeagent/aws/api/v1alpha1"
	"nodeagent/aws/pkg/ebpf"
	"nodeagent/aws/pkg/utils/imds"
	"sync"

	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	goebpf "github.com/jayanthvn/pure-gobpf/pkg/ebpf"

	"github.com/go-logr/logr"
)

// NewPolicyEndpointsReconciler constructs new PolicyEndpointReconciler
func NewPolicyEndpointsReconciler(k8sClient client.Client, log logr.Logger) *PolicyEndpointsReconciler {
	r := &PolicyEndpointsReconciler{
		K8sClient: k8sClient,
		Log:       log,
	}
	r.ebpfClient = ebpf.NewBpfClient(&r.bpfProgMap, &r.policyEndpointIngressMap, &r.policyEndpointEgressMap)
	r.nodeIP, _ = imds.GetMetaData("local-ipv4")

	return r
}

// PolicyEndpointsReconciler reconciles a PolicyEndpoints object
type PolicyEndpointsReconciler struct {
	K8sClient client.Client
	Scheme    *runtime.Scheme
	nodeIP    string
	//Maps eBPF Program FC to Map FD
	bpfProgMap sync.Map
	// Maps PolicyEndpoint resource to Ingress eBPF Program FD
	policyEndpointIngressMap sync.Map
	// Maps PolicyEndpoint resource to Egress eBPF Program FD
	policyEndpointEgressMap sync.Map
	ebpfClient              ebpf.BpfClient

	Log logr.Logger
}

//+kubebuilder:rbac:groups=policy.k8s.aws.nodeagent,resources=policyendpoints,verbs=get;list;watch;create;update;patch;delete
//+kubebuilder:rbac:groups=policy.k8s.aws.nodeagent,resources=policyendpoints/status,verbs=get;update;patch
//+kubebuilder:rbac:groups=policy.k8s.aws.nodeagent,resources=policyendpoints/finalizers,verbs=update

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
// For more details, check Reconcile and its Result here:
// - https://pkg.go.dev/sigs.k8s.io/controller-runtime@v0.14.1/pkg/reconcile
func (r *PolicyEndpointsReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	r.Log.Info("Got reconcile request", "req", req)

	if err := r.reconcile(ctx, req); err != nil {
		r.Log.Info("Reconcile error, requeueing", "err", err)
		return ctrl.Result{Requeue: true}, nil
	}

	return ctrl.Result{}, nil
	//return runtime.HandleReconcileError(r.reconcile(req), r.log)
}

func (r *PolicyEndpointsReconciler) reconcile(ctx context.Context, req ctrl.Request) error {
	//ctx := context.Background()
	policyEndpoint := &policyk8sawsv1.PolicyEndpoints{}

	r.Log.Info("Get Policy Endpoint spec for", "name", req.NamespacedName.Name)
	if err := r.K8sClient.Get(ctx, req.NamespacedName, policyEndpoint); err != nil {
		return client.IgnoreNotFound(err)
	}
	r.Log.Info("Successfully derived Policy Endpoint spec for", "name", req.NamespacedName.Name)

	/*
		if !policyEndpoint.DeletionTimestamp.IsZero() {
			return r.cleanupPolicyEndpoints(ctx, policyEndpoint)
		}
	*/

	return r.reconcilePolicyEndpoint(ctx, policyEndpoint, req)
}

func (r *PolicyEndpointsReconciler) reconcilePolicyEndpoint(ctx context.Context,
	policyEndpoint *policyk8sawsv1.PolicyEndpoints, req ctrl.Request) error {
	ingress, egress := false, false
	//Derive Ingress IPs from the PolicyEndpoint
	ingressCIDRs, egressCIDRs, err := r.deriveIngressAndEgressCIDRs(ctx, policyEndpoint)
	if err != nil {
		r.Log.Info("Error Parsing policy Endpoint resource", "name:", req.NamespacedName.Name)
	}

	if len(ingressCIDRs) > 0 {
		ingress = true
	}

	if len(egressCIDRs) > 0 {
		egress = true
	}

	//1.Derive Pod IPs from Pod Selector field and obtain Pod(s) hostVeth
	//TODO: Maintain a Cache and restore it from ipam.json on restarts
	//podSelectorIPs := policyEndpoint.Spec.PodEndPoints
	//var targetPodNamespacedName []types.NamespacedName
	targetPodList := &corev1.PodList{}

	listOptions := client.ListOptions{
		Namespace: req.NamespacedName.Namespace,
	}

	// For now, get pods under the namespace of PolicyEndpoint resource we're reconciling on
	// and filter based on the Pod selector. If PodSelector is empty, then the policy applies to
	// all the pods under the namespace
	r.Log.Info("Get Pods under ", "namespace", req.NamespacedName.Name)
	//targetPodSelector, _ := metav1.LabelSelectorAsSelector(policyEndpoint.Spec.PodSelector)

	/*
			labelSelector, err := metav1.LabelSelectorAsSelector(&metav1.LabelSelector{
				MatchLabels: map[string]string{
					"k8s-app": "aws-node",
				},
			})
		  podEndpoints :=
	*/

	//Get Pod's name and namespace from ipam.json and derive pod's hostVeth
	r.K8sClient.List(ctx, targetPodList, &listOptions)
	r.Log.Info("Got Pods under ", "namespace", req.NamespacedName.Name)
	r.Log.Info("Node IP - ", "Node IP:", r.nodeIP)

	//Loop over Pod IPs and grab the pods with IPs under selector list
	var matchingPod types.NamespacedName
	for _, pod := range targetPodList.Items {
		r.Log.Info("Pod: ", "name:", pod.Name, "Node IP:", pod.Status.HostIP)
		/*
			if !targetPodSelector.Matches(labels.Set(pod.Labels)) {
				continue
			}
		*/
		if pod.Status.HostIP == r.nodeIP {
			r.Log.Info("Found matching pod", "details", pod.Name)
			matchingPod.Namespace = pod.Namespace
			matchingPod.Name = pod.Name
			//targetPodNamespacedName = append(targetPodNamespacedName, matchingPod)
			policyEndpointIdentifier := req.NamespacedName.Namespace + req.NamespacedName.Name
			err := r.ebpfClient.AttacheBPFProbes(&pod, policyEndpointIdentifier, ingress, egress)
			if err != nil {
				r.Log.Info("Attaching eBPF probe failed for", "pod:", pod.Name, "in namespace", pod.Namespace)
			}
			r.Log.Info("Successfully attached required eBPF probes for", "pod:", pod.Name, "in namespace", pod.Namespace)

			ingressValue, ok := r.policyEndpointIngressMap.Load(policyEndpointIdentifier)
			if ok {
				ingressBpfPgm := ingressValue.(goebpf.BPFProgram)
				//Update Ingress eBPF Map
				if err = r.ebpfClient.UpdateEbpfMap(ingressBpfPgm, ingressCIDRs); err != nil {
					r.Log.Info("Updating Ingress eBPF map failed for", "pod:", pod.Name, "in namespace", pod.Namespace)
				}

			}

			egressValue, ok := r.policyEndpointEgressMap.Load(policyEndpointIdentifier)
			if ok {
				egressBpfPgm := egressValue.(goebpf.BPFProgram)
				//Update Egress eBPF Map
				if err = r.ebpfClient.UpdateEbpfMap(egressBpfPgm, egressCIDRs); err != nil {
					r.Log.Info("Updating Egress eBPF map failed for", "pod:", pod.Name, "in namespace", pod.Namespace)
				}
			}
		}
	}

	return nil
}

func (r *PolicyEndpointsReconciler) deriveIngressAndEgressCIDRs(ctx context.Context,
	policyEndpoint *policyk8sawsv1.PolicyEndpoints) ([]string, []string, error) {
	var ingressCIDRs, egressCIDRs []string

	for _, cidrList := range policyEndpoint.Spec.Ingress {
		for _, cidr := range cidrList.From {
			ingressCIDRs = append(ingressCIDRs, string(cidr.CIDR))
		}
	}

	for _, cidrList := range policyEndpoint.Spec.Egress {
		for _, cidr := range cidrList.To {
			egressCIDRs = append(egressCIDRs, string(cidr.CIDR))
		}
	}

	return ingressCIDRs, egressCIDRs, nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *PolicyEndpointsReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&policyk8sawsv1.PolicyEndpoints{}).
		Complete(r)
}