#!/usr/bin/env bash

# oc get namespace ollama --ignore-not-found

oc new-project ollama

echo "
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 30Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: webui-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 30Gi
" | oc apply -f -

echo "
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      containers:
      - name: ollama
        image: ollama/ollama:latest
        ports:
        - containerPort: 11434
        volumeMounts:
        - name: ollama-data
          mountPath: /.ollama 
        tty: true
      volumes:
      - name: ollama-data
        persistentVolumeClaim:
          claimName: ollama-data
      restartPolicy: Always
      nodeSelector:
        beta.kubernetes.io/instance-type: m5a.12xlarge
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
spec:
  ports:
  - protocol: TCP
    port: 11434
    targetPort: 11434
  selector:
    app: ollama
" | oc apply -f -


echo "
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: open-webui
  template:
    metadata:
      labels:
        app: open-webui
    spec:
      containers:
      - name: open-webui
        image: ghcr.io/open-webui/open-webui:main
        ports:
        - containerPort: 8080
        env:
        - name: OLLAMA_BASE_URL
          value: "http://ollama:11434"
        - name: WEBUI_SECRET_KEY
          value: "your-secret-key"            
        volumeMounts:
        - name: webui-data
          mountPath: /app/backend/data
      volumes:
      - name: webui-data
        persistentVolumeClaim:
          claimName: webui-data
      restartPolicy: Always
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
spec:
  ports:
  - protocol: TCP
    port: 8080
    targetPort: 8080
  selector:
    app: open-webui
" | oc apply -f -

oc create route edge --service open-webui