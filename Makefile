.PHONY: bootstrap deploy verify demo resilience idempotence lint status

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
idempotence:
	python3 scripts/idempotence.py --capture
	$(MAKE) bootstrap
	$(MAKE) deploy
	python3 scripts/idempotence.py
	$(MAKE) verify

lint:
	bash scripts/lint.sh

status:
	kubectl get nodes
	kubectl -n mtc-lab get deployment,gateway,httproute
	kubectl -n mtc-observability get pods,pvc
