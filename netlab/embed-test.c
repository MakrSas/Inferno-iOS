/*
 * Проверка встроенного вывода на Маке.
 *
 * Приложение на телефоне грузит эмулятор библиотекой и читает кадры прямо из
 * его памяти. Здесь то же самое, только вместо SwiftUI — запись PPM: если
 * снимок получился и в нём есть не только чёрный, значит цепочка
 * qemu_init → inferno_display_attach → inferno_display_read работает.
 *
 *   cc -o embed-test embed-test.c && ./embed-test <библиотека> <аргументы qemu…>
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*init_fn)(int, char**);
typedef int (*loop_fn)(void);
typedef void (*attach_fn)(void);
typedef int (*read_fn)(void*, size_t, uint32_t*);

static attach_fn attach;
static read_fn   frame_read;

static void* watcher(void* unused)
{
    uint32_t info[8] = {0};
    uint8_t* buffer  = NULL;
    size_t   size    = 0;
    int      frames  = 0;

    (void)unused;
    /* Ждём, пока машина дойдёт до картинки. */
    sleep(atoi(getenv("EMBED_WAIT") ? getenv("EMBED_WAIT") : "45"));

    for (int tries = 0; tries < 2000; tries++) {
        int rc = frame_read(buffer, size, info);
        if (rc == 2) { /* RESIZE */
            free(buffer);
            size   = (size_t)info[0] * info[1] * 4;
            buffer = calloc(1, size);
            printf("экран %ux%u, буфер %zu Б\n", info[0], info[1], size);
            continue;
        }
        if (rc == 1) { /* OK */
            frames++;
            printf("кадр %d: изменилось %ux%u в (%u,%u)\n", frames, info[5], info[6], info[3], info[4]);
            if (frames >= 3) { break; }
        }
        usleep(20 * 1000);
    }

    if (buffer != NULL && frames > 0) {
        uint32_t w = info[0], h = info[1];
        size_t   nonblack = 0;
        FILE*    out = fopen("embed-test.ppm", "wb");

        fprintf(out, "P6\n%u %u\n255\n", w, h);
        for (size_t i = 0; i < (size_t)w * h; i++) {
            uint8_t b = buffer[i * 4 + 0], g = buffer[i * 4 + 1], r = buffer[i * 4 + 2];
            if ((r | g | b) != 0) { nonblack++; }
            fputc(r, out); fputc(g, out); fputc(b, out);
        }
        fclose(out);
        printf("снимок: embed-test.ppm, непустых пикселей %zu из %u\n", nonblack, w * h);
    }
    else {
        printf("кадров не пришло\n");
    }
    fflush(stdout);
    _exit(frames > 0 ? 0 : 1);
}

int main(int argc, char** argv)
{
    void*     lib;
    init_fn   qemu_init;
    loop_fn   qemu_main_loop;
    pthread_t thread;

    if (argc < 2) { fprintf(stderr, "нужен путь к библиотеке\n"); return 2; }

    lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }

    qemu_init      = (init_fn)dlsym(lib, "qemu_init");
    qemu_main_loop = (loop_fn)dlsym(lib, "qemu_main_loop");
    attach         = (attach_fn)dlsym(lib, "inferno_display_attach");
    frame_read     = (read_fn)dlsym(lib, "inferno_display_read");
    if (!qemu_init || !qemu_main_loop || !attach || !frame_read) {
        fprintf(stderr, "нет одного из символов\n");
        return 2;
    }

    pthread_create(&thread, NULL, watcher, NULL);

    /* argv[0] остаётся именем программы, argv[1] — библиотека, дальше аргументы машины. */
    argv[1] = argv[0];
    qemu_init(argc - 1, argv + 1);
    attach();
    return qemu_main_loop();
}
