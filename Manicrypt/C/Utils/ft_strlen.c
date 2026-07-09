//
//  ft_strlen.c
//  Manicrypt
//
//  Created by Nicolazic Tardy on 08/07/2025.
//

#include "utils.h"

size_t ft_strlen(const char *str) {
    size_t i = 0;
    while (str && str[i])
        i++;
    return (i);
}
