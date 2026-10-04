.PHONY: bootstrap deploy verify demo resilience lint status

bootstrap:
	sudo bash scripts/bootstrap.sh --dedicated-host

deploy:
	bash scripts/deploy.sh

verify:
	python3 scripts/verify.py

demo:
	python3 scripts/verify.py --extended
resilience:
	python3 scripts/resilience.py

lint:
	bash scripts/lint.sh

status:
	kubectl get nodes
	kubectl -n mtc-lab get deployment,gateway,httproute
	kubectl -n mtc-observability get pods,pvc
