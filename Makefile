CFLAGS ?= -O2 -Wall

critters-shape.so: critters-shape.c
	$(CC) $(CFLAGS) -shared -fPIC -o $@ $< $$(pkg-config --cflags --libs xcb xcb-shape)

clean:
	rm -f critters-shape.so

.PHONY: clean
