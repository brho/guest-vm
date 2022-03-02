CFLAGS += -Os -s
CC := gcc

srcs_c := $(wildcard src/*.c)
bins := $(patsubst src/%.c, bin/%, $(srcs_c))

all: $(bins)
	@:

bin/%: src/%.c
	@$(CC) -o $@ $< $(CFLAGS)

clean:
	@rm -f $(bins)

.PHONY: all clean
