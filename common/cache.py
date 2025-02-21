import time

class MemoryCache:
    def __init__(self):
        self._storage = {}
    
    def set(self, key, value, timeout=300):
        self._storage[key] = {
            'value': value,
            'expire': time.time() + timeout
        }
    
    def get(self, key):
        data = self._storage.get(key)
        if data and data['expire'] <= time.time():
            del self._storage[key]
            return None
        return data['value'] if data else None

    def delete(self, key):
        if key in self._storage:
            del self._storage[key]