#!/usr/bin/env python3
import sys
try:
    import yaml
except ImportError:
    sys.exit('Install python3-yaml: sudo apt-get install python3-yaml')

class UniqueLoader(yaml.SafeLoader):
    pass

def mapping(loader, node, deep=False):
    output = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in output:
            raise ValueError(f'Duplicate YAML key: {key}')
        output[key] = loader.construct_object(value_node, deep=deep)
    return output

UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
documents = list(yaml.load_all(sys.stdin.read(), Loader=UniqueLoader))
assert any(isinstance(d, dict) for d in documents), 'Empty or non-mapping YAML'
