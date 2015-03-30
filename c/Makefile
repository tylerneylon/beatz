all: sounds.so

clean:
	rm *.o *.so
	rm ../*.so

sounds.so: sounds.h sounds.m
	clang -fobjc-arc -fmodules -fmodules-prune-interval=86400 -fmodules-prune-after=345600 -o sounds.o -c sounds.m
	clang -shared -o sounds.so sounds.o -framework Foundation -framework CoreAudio -fobjc-arc -fobjc-link-runtime -lluajit -Lluajit
	cp sounds.so ..
