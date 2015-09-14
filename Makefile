lint:
	./node_modules/.bin/coffeelint src test

test:
	gulp test

dist:
	gulp pack

clean:
	rm -rf ./build ./dist

.PHONY: doc
