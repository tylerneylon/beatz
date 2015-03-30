// beatz/c/sounds.c
//

#include "sounds.h"

#include "luajit/lauxlib.h"


// Internal functions.

static int sayhi(lua_State *L) {
  printf("why hello from sayhi\n");
  return 0;
}


// Data for the exported sounds table.

static const struct luaL_Reg sounds[] = {
  {"sayhi", sayhi},
  {NULL, NULL}
};


// Public functions.

int luaopen_sounds(lua_State *L) {
  luaL_register(L, "sounds", sounds);
  return 1;
}

