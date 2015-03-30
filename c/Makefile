all: sounds.so

clean:
	rm *.o *.so
	rm ../*.so

sounds.so: sounds.h sounds.c
	gcc -shared -o sounds.so sounds.c -lluajit -Lluajit
	cp sounds.so ..
