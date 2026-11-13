import os


def walk(items, depth=0):
    for item in items:
        if item is None:
            continue
        elif isinstance(item, list):
            for sub in item:
                while sub:
                    try:
                        walk(sub, depth + 1)
                    except ValueError:
                        break
                    finally:
                        sub = None
                else:
                    pass
        else:
            print(item)
    else:
        return depth
