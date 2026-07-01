CC?=cc
CFLAGS?=-g
LIB=libparse_thing.a

$(LIB): parse_thing.o
	ar rcs $@ $^

parse_thing.o: parse_thing.c parse_thing.h
	$(CC) $(CFLAGS) -c parse_thing.c -o parse_thing.o

clean:
	rm -f parse_thing.o $(LIB)

.PHONY: clean
