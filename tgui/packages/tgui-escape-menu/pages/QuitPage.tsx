type Props = {
  canReturnToLobby?: boolean;
  onNavigate: (page: 'home') => void;
  onAction: (action: string) => void;
};

export function QuitPage({ canReturnToLobby, onNavigate, onAction }: Props) {
  return (
    <div className="escape-menu__quit">
      <div className="escape-menu__quit-prompt">
        {canReturnToLobby
          ? 'Return to the Babylon lobby?'
          : 'Are you sure you wish to quit?'}
      </div>
      <div className="escape-menu__quit-buttons">
        <button
          className="escape-menu__menu-button"
          onClick={() => onAction('quit')}
        >
          {canReturnToLobby ? 'Return to lobby' : 'Yes'}
        </button>
        <button
          className="escape-menu__menu-button"
          onClick={() => onNavigate('home')}
        >
          {canReturnToLobby ? 'Stay in world' : 'No'}
        </button>
      </div>
    </div>
  );
}
