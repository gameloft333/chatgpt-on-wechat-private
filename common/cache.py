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
        if data and data['expire'] > time.time():
            return data['value']
        return None