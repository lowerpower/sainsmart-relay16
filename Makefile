all:
	$(MAKE) -C firmware
	$(MAKE) -C sim

test: all
	python3 -m unittest discover -s test -v

clean:
	$(MAKE) -C firmware clean
	$(MAKE) -C sim clean

.PHONY: all test clean
