"""Local user views and account ownership; these are not login identities."""
def validate(body, account_ids):
    users = body.get('users')
    owners = body.get('accountUsers')
    if not isinstance(users, list) or len(users) > 50 or not isinstance(owners, dict):
        raise ValueError('Invalid users')
    clean, ids, names = [], set(), set()
    for user in users:
        identity, name = user.get('id'), user.get('name')
        if not isinstance(identity, str) or not identity or identity in ids or identity in ('all', 'unassigned') or len(identity) > 80:
            raise ValueError('Invalid user ID')
        if not isinstance(name, str) or not name.strip() or len(name.strip()) > 60 or name.strip().casefold() in names:
            raise ValueError('Use unique, non-empty user names (up to 60 characters)')
        ids.add(identity)
        names.add(name.strip().casefold())
        clean.append({'id': identity, 'name': name.strip()})
    if any(account not in account_ids or owner not in ids for account, owner in owners.items()):
        raise ValueError('Invalid account assignment')
    result = {'users': clean, 'accountUsers': owners}
    if 'accountNicknames' in body:
        nicknames = body['accountNicknames']
        if not isinstance(nicknames, dict):
            raise ValueError('Invalid account nicknames')
        trimmed = {}
        for account, nickname in nicknames.items():
            if account not in account_ids or not isinstance(nickname, str) or len(nickname.strip()) > 60:
                raise ValueError('Use account nicknames up to 60 characters for existing accounts')
            if nickname.strip():
                trimmed[account] = nickname.strip()
        result['accountNicknames'] = trimmed
    return result
