import '@backstage/cli/asset-types';
import ReactDOM from 'react-dom/client';
import App from './App';
import '@backstage/ui/css/styles.css';
import './modules/theme/tuskpilot.css';

ReactDOM.createRoot(document.getElementById('root')!).render(App.createRoot());
