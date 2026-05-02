package main

import (
	"fmt"
	"path/filepath"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

func main() {
	// 1. 获取 kubeconfig 配置文件路径，构建 K8s 客户端配置
	var kubeconfig string
	if home := homedir.HomeDir(); home != "" {
		kubeconfig = filepath.Join(home, ".kube", "config")
	}
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		panic(err.Error())
	}

	// 2. 创建 Kubernetes 客户端
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err.Error())
	}

	// 3. 创建 SharedInformerFactory（工厂模式）
	// 第二个参数 30*time.Second 表示每30秒进行一次全量同步（Resync），防止漏掉事件
	informerFactory := informers.NewSharedInformerFactory(clientset, 30*time.Second)

	// 4. 获取 Pod 资源的 Informer
	podInformer := informerFactory.Core().V1().Pods().Informer()

	// 5. 注册事件处理器 (Add, Update, Delete)
	podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			pod := obj.(*corev1.Pod)
			fmt.Printf("[事件触发] 新增 Pod: %s/%s\n", pod.Namespace, pod.Name)
		},
		UpdateFunc: func(oldObj, newObj interface{}) {
			oldPod := oldObj.(*corev1.Pod)
			newPod := newObj.(*corev1.Pod)
			// 只有当 ResourceVersion 发生变化时才认为是有效更新
			if oldPod.ResourceVersion != newPod.ResourceVersion {
				fmt.Printf("[事件触发] 更新 Pod: %s/%s\n", newPod.Namespace, newPod.Name)
			}
		},
		DeleteFunc: func(obj interface{}) {
			pod := obj.(*corev1.Pod)
			fmt.Printf("[事件触发] 删除 Pod: %s/%s\n", pod.Namespace, pod.Name)
		},
	})

	// 6. 启动 Informer，开始 List & Watch
	stopCh := make(chan struct{})
	defer close(stopCh)
	informerFactory.Start(stopCh)

	// 7. 等待本地缓存同步完成（确保第一次 List 的数据已经拉取完毕）
	if !cache.WaitForCacheSync(stopCh, podInformer.HasSynced) {
		panic("Informer 缓存同步超时")
	}
	fmt.Println("Informer 已启动，正在监听 Pod 变化...")

	// 8. 演示：通过 Lister 直接从本地缓存中获取数据（不请求 API Server）
	podLister := informerFactory.Core().V1().Pods().Lister()
	pods, err := podLister.Pods("default").List(nil)
	if err != nil {
		fmt.Println("从缓存获取 Pod 列表失败:", err)
	} else {
		fmt.Printf("当前 default 命名空间下共有 %d 个 Pod（来自本地缓存）\n", len(pods))
	}

	// 阻塞主线程，保持程序运行以持续监听事件
	<-stopCh
}
