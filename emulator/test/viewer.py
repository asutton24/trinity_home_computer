import pygame


def show(canvas: pygame.Surface, caption: str) -> None:
    """Open a window showing canvas at its native size, until it is closed."""
    window = pygame.display.set_mode(canvas.get_size())
    pygame.display.set_caption(caption)

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False

        window.blit(canvas, (0, 0))
        pygame.display.flip()

    pygame.quit()
